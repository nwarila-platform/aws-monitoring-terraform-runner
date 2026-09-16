# Deploy and confirm recipients

## Before the first deploy

1. **Approve and apply the IAM** in [`docs/reference/aws-iam/`](../reference/aws-iam/README.md).
2. **Set the repository secret** `AWS_ACCOUNT_ID` to the account id.
3. **Merge to `main`.** The deploy creates the trail when `manage_trail = true` and the account has
   none, and stops if a trail already exists, because a second trail bills every management event
   twice. Set `manage_trail = false` in that case.

## Confirming recipients

Each address in `alert_emails` receives two emails from `no-reply@sns.amazonaws.com` titled
"AWS Notification - Subscription Confirmation": one for alerts and one for channel health. Follow
both links. A pending subscription delivers nothing and expires after three days; re-running the
deploy re-sends it. The deploy's job summary lists every subscription and whether it is confirmed.

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
subscription is confirmed, a trail is logging, the rule's `Invocations` metric is non-zero, and the
alert topic's `NumberOfNotificationsFailed` is zero.

## Changing recipients

Edit `alert_emails` in `terraform/prod.tfvars` and merge. Removing an address unsubscribes it.
