# AWS IAM for approval

> **Status: applied.** The role and seven of its policies were created on 2026-09-16 and the
> `…_runner_iam` policy on 2026-09-22; these documents equal the account's export of them as of
> 2026-09-24, with the account and repository ids replaced by placeholders. The account control
> is written but **not attached**, pending the owner's decision recorded in
> [`manifest.json`](manifest.json). A change here is a proposal until it is applied and this
> status says so.

Everything the deploy workflow needs in AWS, and one account control the alerts rely on. Two
values are placeholders: `<account-id>`, and `<repository-id>`, the numeric id of this repository.
[`manifest.json`](manifest.json) lists every document and where each one is attached; the
reconciliation commands below read it, so a document cannot be written here and then forgotten at
apply time.

## The role

| Role | Trusted by | Attached policies |
|---|---|---|
| `nwarila-platform_aws-monitoring-terraform-runner_runner` | GitHub OIDC: `aws-deploy.yaml` on `main` of this repository only | the eight `…_runner_*` below |

The trust requires the `sts.amazonaws.com` audience, this repository's id, `refs/heads/main`, one
of the two `sub` forms GitHub issues for it, and a `job_workflow_ref` naming the one deploy
workflow. A branch, a fork, or another workflow cannot assume it. No inline policies.

## What each policy grants

| Policy | Grants | Bounded by |
|---|---|---|
| `…_cloudtrail` | Read every trail; create and manage one trail | `DescribeTrails` and `ListTrails` take no resource; `GetTrailStatus` and `GetEventSelectors` are granted on `*` because the framework's trail check inspects every trail. Creation needs the `RepositoryId` request tag; management is the one trail ARN `management-events` |
| `…_cloudwatch` | Create, update, tag and delete alarms; read alarm state | Alarm names `security-change-alerts-*`; creation by request tag, changes by resource tag. `DescribeAlarms` is granted on `*` today; the framework reads alarms by name, so a pending change narrows it to `alarm:security-change-alerts-*` |
| `…_iam` | Read this role's own definition | The one role ARN. The framework asks IAM for the deploying role's real ARN, path included, to name it in the KMS key policy |
| `…_events` | Create, update, target, tag and delete rules; test patterns | Rule names `security-change-alerts-*`; creation by request tag, changes by resource tag. `TestEventPattern` takes no resource |
| `…_kms` | Create, manage, alias and schedule deletion of one key | Creation by request tag, because a new key has no ARN; changes by resource tag; the alias is the one name |
| `…_s3` | Read and write this repository's state and lock; list the state bucket; own the trail log bucket | The exact state key and lock; listings limited to this repository's path when a prefix is given; the exact bucket `<account-id>-cloudtrail`. No `DeleteBucket` |
| `…_sns` | Create and manage the alert and health topics and their subscriptions | The two exact topic ARNs; creation also by request tag |
| `…_sqs` | Create and manage the dead-letter queue | The exact queue ARN; creation also by request tag |

Creating a key, a rule, or an alarm with tags also requires the service's tag action, and at that
moment the resource carries no tag to test. Those tag actions are therefore granted alongside
creation under the same request-tag condition, and again under the resource tag for later changes.

Listing the state bucket is conditioned with `StringLikeIfExists`. On the first deploy the state
file does not exist, and S3 answers that read with 404 rather than 403 only for a caller holding
`s3:ListBucket`, through an implicit check whose `s3:prefix` context AWS does not document;
`…IfExists` allows it either way. A listing that names a prefix is held to this repository's path;
one that names none can see the bucket's key names and listing metadata, but never their contents.

## The account control

[`controls/nwarila-platform_us-east-1-only.json`](controls/nwarila-platform_us-east-1-only.json)
denies every action outside `us-east-1`. The alerts watch that region only, and a security group
created anywhere else would raise nothing.

This account is the Organizations management account, where service control policies have no
effect, so the control is an IAM policy instead:

- an inline policy on the `github_nwarila-platform` IAM Identity Center permission set, and
- a customer managed policy attached to every `nwarila-platform_*_runner` role.

IAM's single endpoint is in `us-east-1`, so IAM keeps working. Services whose global endpoint is
elsewhere, such as Global Accelerator in `us-west-2`, are blocked. **This is not complete
protection:** the root user, and any principal created later without the policy, are not bound by
it. Moving workloads out of the management account is AWS's recommended fix and is out of scope.

## Reconciling the account with these documents

After a change here is approved, the account is brought to match the documents: the trust
document is rewritten, and each attached policy gains a new default version. The commands are
read from [`manifest.json`](manifest.json), so a document left out of it is never applied.

```sh
account_id=<account-id>
repository_id="$(gh api repos/nwarila-platform/aws-monitoring-terraform-runner --jq .id)"
role=nwarila-platform_aws-monitoring-terraform-runner_runner

sub() { sed "s/<account-id>/${account_id}/g; s/<repository-id>/${repository_id}/g" "$1"; }

aws iam update-assume-role-policy --role-name "${role}" \
  --policy-document "$(sub "roles/${role}.trust.json")"

jq -r --arg role "${role}" '.roles[$role].attached[]' manifest.json | while read -r document; do
  name="$(basename "${document}" .json)"
  arn="arn:aws:iam::${account_id}:policy/${name}"
  aws iam create-policy-version --policy-arn "${arn}" --set-as-default \
    --policy-document "$(sub "${document}")"
done
```

A policy has at most five versions; delete the oldest non-default version first when a fifth
exists. Then export the role and its policies again and confirm the export equals these
documents, and update the status above with the date.
