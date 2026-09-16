# AWS IAM for approval

> **Status: proposed, awaiting owner approval. Nothing in this directory has been applied.**
> Once applied, these documents are replaced by an export from the account, so that they describe
> what is deployed rather than what was intended.

Everything the deploy workflow needs in AWS, and one account control the alerts rely on. Two values
are placeholders: `<account-id>`, and `<repository-id>`, the numeric id of this repository.
[`manifest.json`](manifest.json) lists every document and where each one is attached; the apply
commands below read it, so a document cannot be written here and then forgotten at apply time.

## The role

| Role | Trusted by | Attached policies |
|---|---|---|
| `nwarila-platform_aws-monitoring-terraform-runner_runner` | GitHub OIDC: `aws-deploy.yaml` on `main` of this repository only | the seven `…_runner_*` below |

Create the role with the default path `/`. The framework names the deploying role in its KMS key
policy by rebuilding the role ARN from the assumed-role session, and a session ARN does not carry
the role's path, so a role on any other path would be named wrongly and key creation would fail.

The trust requires the `sts.amazonaws.com` audience, this repository's id, `refs/heads/main`, one
of the two `sub` forms GitHub issues for it, and a `job_workflow_ref` naming the one deploy
workflow. A branch, a fork, or another workflow cannot assume it. No inline policies.

## What each policy grants

| Policy | Grants | Bounded by |
|---|---|---|
| `…_cloudtrail` | Read every trail; create and manage one trail | Reads take no resource. Creation needs the `RepositoryId` request tag; management is the one trail ARN `management-events` |
| `…_cloudwatch` | Create, update, tag and delete alarms; read alarm state | Alarm names `security-change-alerts-*`; creation by request tag, changes by resource tag. `DescribeAlarms` takes no resource |
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

## Applying after approval

```sh
account_id=<account-id>
repository_id="$(gh api repos/nwarila-platform/aws-monitoring-terraform-runner --jq .id)"
role=nwarila-platform_aws-monitoring-terraform-runner_runner

sub() { sed "s/<account-id>/${account_id}/g; s/<repository-id>/${repository_id}/g" "$1"; }

aws iam create-role --role-name "${role}" \
  --assume-role-policy-document "$(sub "roles/${role}.trust.json")"

jq -r --arg role "${role}" '.roles[$role].attached[]' manifest.json | while read -r document; do
  name="$(basename "${document}" .json)"
  arn="$(aws iam create-policy --policy-name "${name}" \
    --policy-document "$(sub "${document}")" --query Policy.Arn --output text)"
  aws iam attach-role-policy --role-name "${role}" --policy-arn "${arn}"
done
```

Then set the repository secret `AWS_ACCOUNT_ID`, and attach the account control as listed in
[`manifest.json`](manifest.json).
