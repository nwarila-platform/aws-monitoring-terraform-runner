# Deploy and confirm recipients

## Before the first deploy

1. **Approve and apply the IAM** in [`docs/reference/aws-iam/`](../reference/aws-iam/README.md).
2. **Set the repository secrets**: `AWS_ACCOUNT_ID` to the account id, and `ALERT_EMAILS` to the
   recipients as a JSON array, as [Changing recipients](#changing-recipients) shows. The deploy
   refuses to run without either.
3. **Merge to `main`.** The deploy creates the trail when `manage_trail = true` and the account
   has none, and stops if a trail already exists, because a second trail bills every management
   event twice. Set `manage_trail = false` in that case.

## Confirming recipients

Each address in `ALERT_EMAILS` receives two emails from `no-reply@sns.amazonaws.com` titled
"AWS Notification - Subscription Confirmation": one for alerts and one for channel health. Follow
both links. A pending subscription delivers nothing. The deploy's job summary reports how many
addresses are configured, missing, pending and extra per topic; it never prints an address.

Two things leave a subscription pending, and they end differently:

- **Unconfirmed.** SNS deletes a subscription nobody confirmed after 48 hours. While it exists,
  re-running the deploy sends nothing, because Terraform reads it as already present. To have the
  confirmation emails sent again, subscribe the same address to both topics once more, and the
  next deploy adopts them:

  ```sh
  for output in alert_topic_arn health_topic_arn; do
    aws sns subscribe --region us-east-1 --protocol email --notification-endpoint <address> \
      --topic-arn "$(terraform -chdir=<framework>/terraform output -raw "${output}")"
  done
  ```

- **Suspended.** A topic that publishes more than ten messages a second has its email
  subscriptions moved back to pending, where they stay for 30 days unless confirmed again.

The daily read-back fails while any configured address is pending, so a recipient who never
confirms is reported every day rather than never.

## Seeing a real alert

Terraform proves the wiring, not delivery. After both subscriptions are confirmed, make one
harmless change **as yourself**, not from a pipeline, because the roles in `exempt_pipeline_roles`
raise no security-group alert by design:

```sh
aws ec2 update-security-group-rule-descriptions-egress --group-id sg-<any group> \
  --security-group-rules SecurityGroupRuleId=sgr-<any rule>,Description="alert check"
```

It should arrive within a minute or two as a JSON message whose `alert` field reads "Security
group changed". Revert the description afterwards. If nothing arrives, check in this order: the
subscription is confirmed, a trail is logging, the rule's `Invocations` metric is non-zero, and
the alert topic's `NumberOfNotificationsFailed` is zero.

## Changing recipients

Recipients are not in this repository. It is public, so the list lives in the `ALERT_EMAILS`
repository secret and reaches Terraform as a command-line `-var`, which outranks every value
file. Set it as a JSON array of addresses:

```sh
gh secret set ALERT_EMAILS -R nwarila-platform/aws-monitoring-terraform-runner \
  --body '["alerts@example.com", "oncall@example.com"]'
```

Then re-run the deploy. Removing a confirmed address from the secret unsubscribes it on the next
run. Removing an address that is still pending does not: SNS refuses to delete a pending
subscription, so it stays until SNS expires it, up to 48 hours for an unconfirmed one and up to
30 days for a suspended one, and the daily read-back reports one extra subscription and fails
until then. That failure is loud on purpose and heals itself. A missing or malformed secret
fails the deploy before it plans, because a deployment with no recipients applies green and
emails nobody; the value must be a JSON array of strings, so an HCL trailing comma is refused.
