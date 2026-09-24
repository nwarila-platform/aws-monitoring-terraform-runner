#!/usr/bin/env bash
# Proves tools/verify_deployment.sh's decisions offline, as test_check_cloudtrail.sh does for the
# trail gate in the framework. `aws` and `terraform` are shimmed on PATH to answer from
# tools/fixtures/verify/: terraform-show.json is a state as `terraform show -json` prints it, and
# aws-responses.json maps "<service> <operation> [<name or ARN>]" to the response the CLI returns.
# Each case copies the healthy fixtures, changes one thing with jq, and states the exit code and
# the words the report must carry. No case output may carry an address.

set -uo pipefail

tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
failed=0

mkdir -p "${work}/bin"
cat > "${work}/bin/terraform" <<'SHIM'
#!/usr/bin/env bash
[ "$2" = "show" ] && [ "$3" = "-json" ] || { echo "shim: unexpected terraform call: $*" >&2; exit 9; }
cat "${VERIFY_FIXTURES}/terraform-show.json"
SHIM
cat > "${work}/bin/aws" <<'SHIM'
#!/usr/bin/env bash
# The key is the service, the operation, and the one name or ARN the call is about, if any.
key=""; name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --region | --output) shift ;;
    --name | --rule | --topic-arn) name="$2"; shift ;;
    --alarm-names) shift; while [ $# -gt 0 ] && [[ "$1" != --* ]]; do shift; done; continue ;;
    --*) ;;
    *) key="${key:+${key} }$1" ;;
  esac
  shift
done
jq --exit-status --arg key "${key}${name:+ ${name}}" '.[$key]' "${VERIFY_FIXTURES}/aws-responses.json" \
  || { echo "shim: no fixture for '${key}${name:+ ${name}}'" >&2; exit 9; }
SHIM
chmod +x "${work}/bin/terraform" "${work}/bin/aws"

# case <name> <mode> <expected exit> <required output text> <jq edit of aws-responses.json | ->
#       [jq edit of terraform-show.json]
case_() {
  local name="$1" mode="$2" want_exit="$3" want_text="$4" edit="$5" state_edit="${6:-.}" output got_exit
  local dir="${work}/${name}-${mode}"
  mkdir -p "${dir}"
  jq "${state_edit}" "${tools_dir}/fixtures/verify/terraform-show.json" > "${dir}/terraform-show.json"
  if [ "${edit}" = "-" ]; then
    cp "${tools_dir}/fixtures/verify/aws-responses.json" "${dir}/"
  else
    jq "${edit}" "${tools_dir}/fixtures/verify/aws-responses.json" > "${dir}/aws-responses.json"
  fi
  output="$(PATH="${work}/bin:${PATH}" VERIFY_FIXTURES="${dir}" AWS_REGION=us-east-1 \
    bash "${tools_dir}/verify_deployment.sh" /unused "${mode}" 2>&1)"
  got_exit=$?
  if [ "${got_exit}" -ne "${want_exit}" ] || ! printf '%s' "${output}" | grep -q -- "${want_text}"; then
    printf 'FAIL %-44s %-10s exit %s (wanted %s), wanted text: %s\n%s\n' "${name}" "${mode}" "${got_exit}" "${want_exit}" "${want_text}" "${output}" >&2
    failed=1
  elif printf '%s' "${output}" | grep -q '@'; then
    printf 'FAIL %-44s %-10s the report carries an address\n' "${name}" "${mode}" >&2
    failed=1
  else
    printf 'ok   %-44s %-10s exit %s\n' "${name}" "${mode}" "${got_exit}"
  fi
}

alert='arn:aws:sns:us-east-1:123456789012:security-change-alerts'
health="${alert}-health"

case_ healthy strict 0 'verify_deployment (strict): OK' -
case_ healthy post-apply 0 'verify_deployment (post-apply): OK' -
# A recipient who has not followed the confirmation link: a first deploy's normal state, a
# scheduled check's failure.
pending='.["sns list-subscriptions-by-topic '"${health}"'"].Subscriptions[0].SubscriptionArn = "PendingConfirmation"'
case_ pending_recipient post-apply 0 'recipient(s) pending confirmation; each must follow' "${pending}"
case_ pending_recipient strict 1 '1 recipient(s) still pending' "${pending}"
# A configured address with no subscription at all receives nothing, whichever mode.
missing='.["sns list-subscriptions-by-topic '"${alert}"'"].Subscriptions |= .[1:]'
case_ missing_recipient post-apply 1 '1 missing' "${missing}"
case_ missing_recipient strict 1 '1 missing' "${missing}"
# A subscription the configuration does not name: a removed address SNS has not yet deleted.
extra='.["sns list-subscriptions-by-topic '"${alert}"'"].Subscriptions += [{"SubscriptionArn":"PendingConfirmation","Protocol":"email","Endpoint":"former@example.com"}]'
case_ extra_subscription post-apply 0 'a removed address stays pending' "${extra}"
case_ extra_subscription strict 1 'not in the configured list' "${extra}"
# An alarm in ALARM is a channel that is failing now; only the scheduled check treats it as such.
alarm='(.["cloudwatch describe-alarms"].MetricAlarms[] | select(.AlarmName == "security-change-alerts-undelivered") | .StateValue) = "ALARM"'
case_ alarm_in_alarm post-apply 0 'as applied, ALARM' "${alarm}"
case_ alarm_in_alarm strict 1 'is in ALARM' "${alarm}"
# A new alarm has no data yet; only ALARM is a failing channel.
case_ alarm_insufficient_data strict 0 'as applied, INSUFFICIENT_DATA' '(.["cloudwatch describe-alarms"].MetricAlarms[] | select(.AlarmName == "security-change-alerts-undelivered") | .StateValue) = "INSUFFICIENT_DATA"'
# A subscriber of any other protocol would receive every alert; nothing here creates one.
siphon='.["sns list-subscriptions-by-topic '"${alert}"'"].Subscriptions += [{"SubscriptionArn":"'"${alert}"':00000009-0000-0000-0000-000000000000","Protocol":"lambda","Endpoint":"arn:aws:lambda:us-east-1:123456789012:function:elsewhere"}]'
case_ non_email_subscription post-apply 0 '1 extra' "${siphon}"
case_ non_email_subscription strict 1 'not in the configured list' "${siphon}"
# A configured address subscribed under another protocol is not the email subscription it needs.
json_protocol='.["sns list-subscriptions-by-topic '"${health}"'"].Subscriptions[0].Protocol = "email-json"'
case_ configured_address_as_email_json strict 1 '1 missing' "${json_protocol}"
# A state that lists nothing to check is refused, never passed.
case_ state_without_rules strict 1 'lists no alert rules' - 'del(.values.outputs.alert_rules)'
case_ state_without_alarms strict 1 'lists no health alarms' - '.values.outputs.health_alarms.value = []'
# A list of another shape is refused rather than read as if it were the expected one.
case_ state_rules_not_a_map strict 5 'alert_rules is not a map' - '.values.outputs.alert_rules.value |= [.[]]'
case_ state_alarms_not_a_list strict 5 'health_alarms is not a list' - '.values.outputs.health_alarms.value |= (to_entries | map({key: (.key | tostring), value}) | from_entries)'
case_ rule_disabled strict 1 'is not ENABLED' '.["events describe-rule security-change-alerts-iam"].State = "DISABLED"'
case_ rule_with_two_targets strict 1 'has 2 targets' '.["events list-targets-by-rule security-change-alerts-iam"].Targets |= . + .'
case_ target_retry_changed strict 1 "target differs" '.["events list-targets-by-rule security-change-alerts-iam"].Targets[0].RetryPolicy.MaximumEventAgeInSeconds = 86400'
case_ target_without_dead_letter strict 1 "target differs" 'del(.["events list-targets-by-rule security-change-alerts-cloudtrail"].Targets[0].DeadLetterConfig)'
case_ alert_topic_key_changed strict 1 'is encrypted with' '.["sns get-topic-attributes '"${alert}"'"].Attributes.KmsMasterKeyId = "alias/aws/sns"'
case_ health_topic_carries_a_key strict 1 "Terraform applied 'nothing'" '.["sns get-topic-attributes '"${health}"'"].Attributes.KmsMasterKeyId = "12345678-1234-1234-1234-123456789012"'
case_ health_policy_widened strict 1 'policy differs' '.["sns get-topic-attributes '"${health}"'"].Attributes.Policy |= (fromjson | .Statement[0].Condition = {"StringEquals":{"aws:SourceAccount":"123456789012"}} | tojson)'
case_ alert_policy_extra_statement strict 1 'policy differs' '.["sns get-topic-attributes '"${alert}"'"].Attributes.Policy |= (fromjson | .Statement += [{"Sid":"Anyone","Effect":"Allow","Principal":"*","Action":"sns:Publish","Resource":"'"${alert}"'"}] | tojson)'
# The same policy with its one-element lists spelled as lists is the same policy.
case_ policy_spelled_with_lists strict 0 'verify_deployment (strict): OK' '.["sns get-topic-attributes '"${alert}"'"].Attributes.Policy |= (fromjson | .Statement[0].Action = ["sns:Publish"] | .Statement[0].Resource = ["'"${alert}"'"] | tojson)'
case_ alarm_missing strict 1 'does not exist' '.["cloudwatch describe-alarms"].MetricAlarms |= map(select(.AlarmName != "security-change-alerts-undelivered"))'
case_ alarm_actions_disabled strict 1 'differs from what Terraform applied' '(.["cloudwatch describe-alarms"].MetricAlarms[] | select(.AlarmName == "security-change-alerts-iam-failed-invocations") | .ActionsEnabled) = false'
case_ alarm_dimension_changed strict 1 'differs from what Terraform applied' '(.["cloudwatch describe-alarms"].MetricAlarms[] | select(.AlarmName == "security-change-alerts-undelivered") | .Dimensions[0].Value) = "some-other-queue"'
case_ alarm_ok_action_removed strict 1 'differs from what Terraform applied' '(.["cloudwatch describe-alarms"].MetricAlarms[] | select(.AlarmName == "security-change-alerts-notification-failures") | .OKActions) = []'
case_ alarm_insufficient_data_action_added strict 1 'differs from what Terraform applied' '(.["cloudwatch describe-alarms"].MetricAlarms[] | select(.AlarmName == "security-change-alerts-undelivered") | .InsufficientDataActions) = ["arn:aws:sns:us-east-1:123456789012:elsewhere"]'

if [ "${failed}" -ne 0 ]; then
  echo "verify_deployment.sh does not decide every case as required" >&2
  exit 1
fi
echo "test_verify_deployment: OK — every case decided as required, no report carries an address"
