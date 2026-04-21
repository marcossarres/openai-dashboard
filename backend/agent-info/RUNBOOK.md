# RUNBOOK.md – AwsCloudy

Keep this file updated with approved deployment commands, scripts, and troubleshooting steps.

## Profiles & Roles
- AWS profile: `aws-cloudy`
- IAM user: `openclaw`
- Default region: `us-east-1` (update if different)

## Standard Deployment Flow
1. Validate request (ticket, branch, target stack, environment).
2. Run plan/changeset:
   ```bash
   aws cloudformation deploy \
     --stack-name <stack> \
     --template-file infra/stack.yaml \
     --no-execute-changeset \
     --profile aws-cloudy
   ```
3. Post plan output, wait for explicit GO.
4. Execute apply:
   ```bash
   aws cloudformation deploy --stack-name <stack> --template-file infra/stack.yaml --profile aws-cloudy
   ```
5. Verify (CloudWatch alarms, smoke tests, logs).
6. Update this RUNBOOK + logs with results.

## Rollback Guidance
- Use `aws cloudformation cancel-update-stack` if update is still running.
- Revert to previous artifact/tag and redeploy.
- Document root cause + mitigation.
