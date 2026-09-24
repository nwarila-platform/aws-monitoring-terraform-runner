#!/usr/bin/env bash
# Read the deployed monitoring back from AWS and fail on anything that differs from what Terraform
# last applied. Terraform's own report is not the proof: a rule can be disabled, a subscription
# removed, or a topic policy rewritten with no plan ever seeing it.
#
#   verify_deployment.sh <framework terraform dir> post-apply
#       After an apply. A configured address missing from either topic fails; a pending or an
#       extra one warns, because a first deploy has pending subscriptions until the recipients
#       confirm them, and a removed address stays pending until SNS deletes it.
#   verify_deployment.sh <framework terraform dir> strict
#       On a schedule, with no apply. Missing, pending and extra addresses all fail, and so does
#       any alarm in ALARM: a scheduled run exists to notice what changed since the last converge.
#
# Everything expected comes from `terraform show -json`: the outputs, and the topic policies, the
# targets and the alarms as Terraform last applied them. Never prints an endpoint: an address
# that is missing, extra or pending is reported as a count per topic, so nothing here can leak a
# recipient even when the log's masks do not know it. Read-only in AWS: describe-rule,
# list-targets-by-rule, get-topic-attributes, list-subscriptions-by-topic, describe-alarms.

set -euo pipefail

terraform_dir="${1:?usage: verify_deployment.sh <framework terraform dir> post-apply|strict}"
mode="${2:?usage: verify_deployment.sh <framework terraform dir> post-apply|strict}"
region="${AWS_REGION:?AWS_REGION must name the region the monitoring is deployed in}"
case "${mode}" in post-apply | strict) ;; *) echo "mode must be post-apply or strict, not ${mode}" >&2; exit 2 ;; esac

failed=0
fail() { echo "::error::$*" >&2; failed=1; }
warn() { echo "::warning::$*" >&2; }

state="$(terraform -chdir="${terraform_dir}" show -json)"
expect() { printf '%s' "${state}" | jq -c "$@"; }
live() { aws --region "${region}" --output json "$@"; }

# IAM reads a policy as a set of statements whose single-element lists mean the same as the
# element alone, so both documents are put in that one shape before they are compared. The
# comparison itself is jq's, because jq keeps a number's original spelling and 1.0 is 1.
canon='def canon:
  if type == "object" then to_entries | sort_by(.key) | map(.value |= canon) | from_entries
  elif type == "array" then map(canon) | if length == 1 then .[0] else sort end
  else . end;'
same() { jq --exit-status -n --argjson a "$1" --argjson b "$2" '$a == $b' > /dev/null; }

alert_topic="$(expect -r '.values.outputs.alert_topic_arn.value')"
health_topic="$(expect -r '.values.outputs.health_topic_arn.value')"

#region ------ [ Rules and targets ] ------------------------------------------------------------ #

while read -r rule; do
  name="$(printf '%s' "${rule}" | jq -r .name)"
  key="$(printf '%s' "${rule}" | jq -r .key)"
  described="$(live events describe-rule --name "${name}")"
  if [ "$(printf '%s' "${described}" | jq -r '[.State, .EventBusName] | join(" ")')" != "ENABLED default" ]; then
    fail "Rule ${name} is not ENABLED on the default bus."
    continue
  fi
  targets="$(live events list-targets-by-rule --rule "${name}")"
  if [ "$(printf '%s' "${targets}" | jq '.Targets | length')" -ne 1 ]; then
    fail "Rule ${name} has $(printf '%s' "${targets}" | jq '.Targets | length') targets; expected exactly one."
    continue
  fi
  actual="$(printf '%s' "${targets}" | jq -c "${canon}"'.Targets[0]
    | { arn: .Arn, dead_letter: .DeadLetterConfig.Arn,
        retry: { age: .RetryPolicy.MaximumEventAgeInSeconds, attempts: .RetryPolicy.MaximumRetryAttempts },
        paths: .InputTransformer.InputPathsMap, template: .InputTransformer.InputTemplate } | canon')"
  expected="$(expect --arg key "${key}" "${canon}"'.values.root_module.resources[]
    | select(.address == "aws_cloudwatch_event_target.us_east_1[\"" + $key + "\"]") | .values
    | { arn, dead_letter: .dead_letter_config[0].arn,
        retry: { age: .retry_policy[0].maximum_event_age_in_seconds, attempts: .retry_policy[0].maximum_retry_attempts },
        paths: .input_transformer[0].input_paths, template: .input_transformer[0].input_template } | canon')"
  if ! same "${actual}" "${expected}"; then
    fail "Rule ${name}'s target differs from what Terraform applied (topic, dead-letter queue, retry policy or transformer)."
    continue
  fi
  echo "rule ${name}: ENABLED on the default bus, one target as applied"
done < <(expect '.values.outputs.alert_rules.value | to_entries[] | { key: .key, name: .value.name }')

#endregion --- [ Rules and targets ] ------------------------------------------------------------ #


#region ------ [ Topics ] ----------------------------------------------------------------------- #

check_topic() {
  local arn="$1" address="$2" expected_key="$3" attributes actual_key
  attributes="$(live sns get-topic-attributes --topic-arn "${arn}" | jq -c '.Attributes')"
  actual_key="$(printf '%s' "${attributes}" | jq -r '.KmsMasterKeyId // ""')"
  if [ "${actual_key}" != "${expected_key}" ]; then
    fail "Topic ${arn##*:} is encrypted with '${actual_key:-nothing}'; Terraform applied '${expected_key:-nothing}'."
    return
  fi
  local actual_policy expected_policy
  actual_policy="$(printf '%s' "${attributes}" | jq -c "${canon}"'.Policy | fromjson | canon')"
  expected_policy="$(expect --arg address "${address}" "${canon}"'.values.root_module.resources[]
    | select(.address == $address) | .values.policy | fromjson | canon')"
  if ! same "${actual_policy}" "${expected_policy}"; then
    fail "Topic ${arn##*:}'s policy differs from what Terraform applied."
    return
  fi
  echo "topic ${arn##*:}: key '${actual_key:-none}' and policy as applied"
}

check_topic "${alert_topic}" aws_sns_topic_policy.us_east_1 \
  "$(expect -r '.values.root_module.resources[] | select(.address == "aws_sns_topic.us_east_1") | .values.kms_master_key_id')"
check_topic "${health_topic}" aws_sns_topic_policy.us_east_1_health ""

#endregion --- [ Topics ] ----------------------------------------------------------------------- #


#region ------ [ Subscriptions ] ---------------------------------------------------------------- #

# Addresses are compared as sets and reported as counts. The configured list is the sensitive
# output, read here and never echoed.
configured="$(expect '.values.outputs.alert_subscriptions.value | keys')"

check_subscriptions() {
  local arn="$1" subscriptions missing extra pending
  subscriptions="$(live sns list-subscriptions-by-topic --topic-arn "${arn}" \
    | jq -c '[.Subscriptions[] | select(.Protocol == "email")]')"
  missing="$(jq -n --argjson want "${configured}" --argjson have "${subscriptions}" \
    '$want - [$have[].Endpoint] | length')"
  extra="$(jq -n --argjson want "${configured}" --argjson have "${subscriptions}" \
    '[$have[].Endpoint] - $want | length')"
  pending="$(jq -n --argjson want "${configured}" --argjson have "${subscriptions}" \
    '[$have[] | select(.SubscriptionArn == "PendingConfirmation" and (.Endpoint | IN($want[])))] | length')"
  echo "topic ${arn##*:}: $(jq -n --argjson w "${configured}" '$w | length') configured, ${missing} missing, ${pending} pending, ${extra} extra"

  if [ "${missing}" -gt 0 ]; then
    fail "Topic ${arn##*:} is missing ${missing} configured recipient(s); they receive nothing."
  fi
  if [ "${pending}" -gt 0 ]; then
    if [ "${mode}" = strict ]; then
      fail "Topic ${arn##*:} has ${pending} recipient(s) still pending confirmation; they receive nothing."
    else
      warn "Topic ${arn##*:} has ${pending} recipient(s) pending confirmation; each must follow the link SNS emailed them."
    fi
  fi
  if [ "${extra}" -gt 0 ]; then
    if [ "${mode}" = strict ]; then
      fail "Topic ${arn##*:} has ${extra} subscription(s) not in the configured list."
    else
      warn "Topic ${arn##*:} has ${extra} subscription(s) not in the configured list; a removed address stays pending until SNS deletes it."
    fi
  fi
}

check_subscriptions "${alert_topic}"
check_subscriptions "${health_topic}"

#endregion --- [ Subscriptions ] ---------------------------------------------------------------- #


#region ------ [ Alarms ] ----------------------------------------------------------------------- #

mapfile -t alarm_names < <(expect -r '.values.outputs.health_alarms.value[]')
alarms="$(live cloudwatch describe-alarms --alarm-names "${alarm_names[@]}")"

for name in "${alarm_names[@]}"; do
  actual="$(printf '%s' "${alarms}" | jq -c --arg name "${name}" "${canon}"'[.MetricAlarms[] | select(.AlarmName == $name)]
    | if length == 0 then empty else .[0]
    | { enabled: .ActionsEnabled, alarm_actions: .AlarmActions, ok_actions: .OKActions,
        metric: .MetricName, namespace: .Namespace,
        dimensions: (.Dimensions | map({ key: .Name, value: .Value }) | from_entries),
        statistic: .Statistic, period: .Period, threshold: .Threshold,
        comparison: .ComparisonOperator, evaluation_periods: .EvaluationPeriods,
        datapoints: .DatapointsToAlarm, missing_data: .TreatMissingData } | canon end')"
  if [ -z "${actual}" ]; then
    fail "Alarm ${name} does not exist; the alert channel is unwatched."
    continue
  fi
  expected="$(expect --arg name "${name}" "${canon}"'.values.root_module.resources[]
    | select(.type == "aws_cloudwatch_metric_alarm" and .values.alarm_name == $name) | .values
    | { enabled: .actions_enabled, alarm_actions, ok_actions,
        metric: .metric_name, namespace, dimensions,
        statistic, period, threshold, comparison: .comparison_operator,
        evaluation_periods, datapoints: .datapoints_to_alarm, missing_data: .treat_missing_data } | canon')"
  if ! same "${actual}" "${expected}"; then
    fail "Alarm ${name} differs from what Terraform applied (metric, dimensions, actions or thresholds)."
    continue
  fi
  state_value="$(printf '%s' "${alarms}" | jq -r --arg name "${name}" '.MetricAlarms[] | select(.AlarmName == $name) | .StateValue')"
  if [ "${mode}" = strict ] && [ "${state_value}" = ALARM ]; then
    fail "Alarm ${name} is in ALARM: the alert channel is failing."
    continue
  fi
  echo "alarm ${name}: as applied, ${state_value}"
done

#endregion --- [ Alarms ] ----------------------------------------------------------------------- #

if [ "${failed}" -ne 0 ]; then
  echo "::error::The deployed monitoring does not match what Terraform applied." >&2
  exit 1
fi
echo "verify_deployment (${mode}): OK — rules, targets, topics, subscriptions and alarms match what Terraform applied"
