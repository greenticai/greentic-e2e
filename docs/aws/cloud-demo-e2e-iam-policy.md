# Cloud Demo E2E — AWS IAM setup

The `cloud-demo-e2e.yml` workflow deploys a full ECS-Fargate stack via terraform: VPC + subnets + IGW + route tables, ALB + target group + listener, ECS cluster + service + task definition, IAM execution role with inline policies, CloudWatch log group, and Secrets Manager secrets for admin TLS material. State is held in an S3 backend.

The IAM principal whose access keys are wired to `secrets.AWS_ACCESS_KEY_ID` / `secrets.AWS_SECRET_ACCESS_KEY` therefore needs deploy-grade permissions in `eu-north-1` (the default region).

## Minimum policy

`cloud-demo-e2e-iam-policy.json` in this directory is a starting point. Before attaching:

1. Replace `REPLACE_WITH_TF_STATE_BUCKET` with the S3 bucket holding the terraform state for this workflow.
2. Replace `REPLACE_WITH_TF_STATE_LOCK_TABLE` with the DynamoDB lock table name (drop the statement if you don't use one).
3. Optionally narrow the IAM `Resource` from `arn:aws:iam::599558443099:role/greentic-*` to the exact role names the deployer creates (`greentic-<8hex>-task-exec` is the current pattern).
4. Optionally drop SecretsManager if you bring TLS material out-of-band.

Each statement is region-pinned to `eu-north-1` via `aws:RequestedRegion` where the AWS service supports it (IAM and S3 don't, hence narrower `Resource` scopes).

## Recommended setup

Don't attach this to `org-ci-codeartifact` (mixing CodeArtifact perms with deploy perms is a blast-radius problem). Create a dedicated IAM principal:

```bash
# 1. Create the IAM user
aws iam create-user --user-name cloud-demo-e2e-deploy

# 2. Create the policy from the JSON in this directory
aws iam create-policy \
  --policy-name CloudDemoE2eDeploy \
  --policy-document file://docs/aws/cloud-demo-e2e-iam-policy.json

# 3. Attach
aws iam attach-user-policy \
  --user-name cloud-demo-e2e-deploy \
  --policy-arn arn:aws:iam::599558443099:policy/CloudDemoE2eDeploy

# 4. Mint access keys; rotate annually
aws iam create-access-key --user-name cloud-demo-e2e-deploy

# 5. Update the GitHub repo secrets
#    https://github.com/greenticai/greentic-e2e/settings/secrets/actions
#    Replace AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.
```

Even better, switch the workflow to GitHub OIDC + an assume-role flow so no static keys live in repo secrets. That's a separate piece of work — this policy works for whichever principal you pick.

## Verifying the keys before merging

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=eu-north-1
aws sts get-caller-identity
aws ec2 describe-availability-zones --region eu-north-1   # must return AZs, not 403
```

If both calls succeed, dispatching `cloud-demo-e2e.yml` should reach actual resource creation.
