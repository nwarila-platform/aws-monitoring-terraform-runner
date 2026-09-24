# aws-monitoring-terraform-runner

Deploys
[aws-monitoring-terraform-framework](https://github.com/nwarila-platform/aws-monitoring-terraform-framework)
to the organization's AWS account. The framework is the code; this repository is the one
deployment of it: who is emailed, whether the framework creates the CloudTrail trail, which deploy
pipelines are exempt from security-group alerts, and the workflow that applies it.

## How it deploys

Every merge to `main` runs [`aws-deploy.yaml`](.github/workflows/aws-deploy.yaml). Each converge
rewrites the `RunId` provenance tag on every resource, and `CommitSha` when this repository's
commit changed, so no converge is a no-op plan. It:

1. checks out the framework at the commit in
   [`.github/terraform-framework-pin`](.github/terraform-framework-pin);
2. assumes the deploy role over GitHub OIDC and plans with
   [`terraform/prod.tfvars`](terraform/prod.tfvars), with the recipients from a secret, masked
   from the log;
3. refuses to create a second CloudTrail trail, or to proceed with none;
4. proves every planned event pattern against EventBridge before applying;
5. applies the saved plan; and
6. reads the rules, targets, topics, subscriptions and alarms back from AWS with
   [`tools/verify_deployment.sh`](tools/verify_deployment.sh), failing on any mismatch with what
   Terraform applied.

Once a day the same workflow runs the read-back alone, with no apply, in strict mode: a
subscription lost, an alarm in ALARM, or a rule disabled since the last converge fails that run.
A manual dispatch with `read_back_only` runs that same strict read-back on demand:

```sh
gh workflow run aws-deploy.yaml -R nwarila-platform/aws-monitoring-terraform-runner \
  -f read_back_only=true
```

The job summary reports counts per topic, never an address.

Adopting a newer framework commit is a pull request that changes the pin, checked against the
framework's permission table: a release that needs a call the deploy role lacks needs the IAM
change first.

## Before the first deploy

- The IAM in [`docs/reference/aws-iam/`](docs/reference/aws-iam/README.md) is applied, as its
  status records.
- The repository secret `AWS_ACCOUNT_ID` must hold the account id, and `ALERT_EMAILS` a JSON
  array of recipient addresses.
- Each recipient confirms two subscription emails after the first deploy.

See [deploy and confirm recipients](docs/how-to/deploy-and-confirm-recipients.md).
