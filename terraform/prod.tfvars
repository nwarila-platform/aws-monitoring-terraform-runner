# The organization account's monitoring deployment. Deployment identity (repository,
# repository_id, commit_sha, run_id) is NOT set here: the deploy workflow passes it as
# command-line -var arguments, which outrank every value file.

# The alerts protect the real account.
environment = "prod"

# alert_emails is deliberately absent. This repository is public, so the recipients arrive from
# the ALERT_EMAILS repository secret as a command-line -var, which outranks this file. The deploy
# refuses to run without it rather than creating a channel that emails nobody. Each address
# confirms two SNS subscriptions, one for alerts and one for channel health, before anything is
# delivered.

# Neither account in the organization had a trail on 2026-09-16, and the alerts cannot fire
# without one.
manage_trail = true

# This account has no key-approval process, so the framework creates and owns the key that
# encrypts the alert topics.
alert_key_alias = null

# The deploy pipelines whose security-group churn is not emailed. Every one of them assumes a role
# named nwarila-platform_<repository>_runner, so one pattern covers the fleet, including
# repositories added later. Their IAM changes still alert, and so does every change made by a
# person.
exempt_pipeline_roles = ["nwarila-platform_*_runner"]
