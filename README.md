# aws-monitoring-terraform-runner

Deploys [aws-monitoring-terraform-framework](https://github.com/nwarila-platform/aws-monitoring-terraform-framework)
to the organization's AWS account. The framework is the code; this repository is the one
deployment of it: who is emailed, whether the framework creates the CloudTrail trail, which deploy
pipelines are exempt from security-group alerts, and the workflow that applies it.

## How it deploys

Every merge to `main` runs [`aws-deploy.yaml`](.github/workflows/aws-deploy.yaml). Each run rewrites the `CommitSha` and `RunId` provenance tags on every resource, so no run is a no-op plan. It:

1. checks out the framework at the commit in [`.github/terraform-framework-pin`](.github/terraform-framework-pin);
2. assumes the deploy role over GitHub OIDC and plans with [`terraform/prod.tfvars`](terraform/prod.tfvars);
3. refuses to create a second CloudTrail trail, or to proceed with none;
4. proves every planned event pattern against EventBridge before applying;
5. applies the saved plan; and
6. reads the rules, topics, subscriptions and alarms back from AWS, failing on any mismatch.

Adopting a newer framework commit is a pull request that changes the pin.

## Before the first deploy

- The IAM in [`docs/reference/aws-iam/`](docs/reference/aws-iam/README.md) is **proposed and
  awaiting approval**. Nothing there has been applied.
- The repository secret `AWS_ACCOUNT_ID` must hold the account id.
- Each recipient confirms two subscription emails after the first deploy.

See [deploy and confirm recipients](docs/how-to/deploy-and-confirm-recipients.md).
