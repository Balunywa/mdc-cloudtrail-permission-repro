# Defender for Cloud AWS CloudTrail Permission Reproduction

This repository creates a temporary, isolated AWS lab that reproduces a common
Defender for Cloud CloudTrail ingestion failure:

1. An IAM role can consume an SQS notification.
2. The same role cannot download the referenced object from S3.
3. AWS returns `AccessDenied` because `s3:GetObject` is missing.
4. A least-privilege policy is applied.
5. The same role successfully downloads the same object.

The lab uses a synthetic CloudTrail-shaped object. It does **not** create or
modify a real Defender for Cloud connector or an AWS CloudTrail trail.

## What the lab creates

- One encrypted S3 bucket with public access blocked
- One encrypted SQS queue
- One SQS queue policy allowing S3 notifications from the current account
- One IAM role trusted by the current AWS account
- An initial SQS-only inline policy
- An optional S3 read policy used to demonstrate the fix

The default stack name is `mdc-cloudtrail-permission-repro`.

## Prerequisites

- An isolated AWS test account or approved sandbox
- AWS CloudShell, or Bash with AWS CLI v2
- Credentials authorized to manage CloudFormation, IAM, S3, SQS, and STS
- Permission to assume the IAM role created by the stack

Confirm the intended account before deploying:

```bash
aws sts get-caller-identity
```

## Fast end-to-end reproduction

Open AWS CloudShell, clone the repository, and run:

```bash
git clone https://github.com/Balunywa/mdc-cloudtrail-permission-repro.git
cd mdc-cloudtrail-permission-repro
chmod +x scripts/*.sh
./scripts/run-demo.sh
```

`run-demo.sh` stops after proving the fix so the resources remain available for
inspection. It does not tear down the stack automatically.

Expected result:

```text
PASS: the role can read SQS queue attributes.
PASS: S3 access was denied as expected before the fix.
PASS: the same role downloaded the same object after the fix.
```

## Run each stage manually

### 1. Deploy the intentionally broken state

```bash
./scripts/deploy.sh
```

The script deploys the stack without S3 read permissions and uploads a
synthetic object. S3 sends an object-created notification to SQS.

### 2. Prove the permission failure

```bash
./scripts/test-access.sh denied
```

The test assumes the lab role, confirms that the role can call SQS, and then
asserts that downloading the object fails with `AccessDenied`.

### 3. Apply the least-privilege fix

```bash
./scripts/apply-fix.sh
```

The update adds:

- `s3:GetBucketLocation` on the bucket
- `s3:ListBucket` on the bucket, restricted to the test prefix
- `s3:GetObject` on objects under the test prefix

### 4. Prove the same request succeeds

```bash
./scripts/test-access.sh success
```

### 5. Collect evidence

```bash
./scripts/collect-evidence.sh
```

Evidence is written under `.evidence/<UTC timestamp>/`. Temporary STS
credentials are never written to the evidence files.

### 6. Tear down all lab resources

```bash
./scripts/teardown.sh
```

The teardown script resolves the bucket from CloudFormation, empties it, deletes
the stack, and waits for `DELETE_COMPLETE`.

## Provision an existing CloudTrail pipeline

For Defender for Cloud's **Manually provide trail details** option, deploy the
production-shaped pipeline template:

```bash
aws cloudformation deploy \
  --region us-east-1 \
  --stack-name mdc-existing-cloudtrail \
  --template-file infrastructure/existing-cloudtrail-template.json
```

The stack creates a multi-Region management-event trail, encrypted S3 bucket,
dedicated encrypted Standard SQS queue, S3 event notification, and required
resource policies. Retrieve the values to enter in Defender for Cloud:

```bash
aws cloudformation describe-stacks \
  --region us-east-1 \
  --stack-name mdc-existing-cloudtrail \
  --query "Stacks[0].Outputs" \
  --output table
```

Use `CloudTrailBucketArn` for the S3 bucket ARN and `CloudTrailQueueArn` for the
SQS ARN. The Defender-generated onboarding stack is still required because it
creates the Microsoft access roles and OIDC providers.

## Optional configuration

All scripts accept these environment variables:

```bash
export AWS_REGION=us-east-2
export STACK_NAME=mdc-cloudtrail-permission-repro
export TEST_PREFIX=AWSLogs/repro/CloudTrail
```

Use a unique stack name if multiple people share the same account.

## What to validate in a customer environment

The effective authorization path is:

```text
Defender for Cloud -> connector IAM role -> SQS -> S3 -> optional KMS
```

Checking only the IAM role is not sufficient. Validate:

- The exact role ARN configured in the Defender connector
- IAM identity policies on that role
- The SQS queue policy
- The S3 bucket policy
- The KMS key policy and `kms:Decrypt` when SSE-KMS is used
- AWS Organizations service control policies
- Cross-account access when logs are centralized in a log archive account

For production, prefer regenerating and updating the current Defender for Cloud
CloudFormation onboarding template rather than maintaining a hand-written
connector policy.

## About the out-of-memory warning

This lab addresses AWS authorization only. If all effective permissions pass
and the out-of-memory warning remains, treat it as a separate ingestion issue
and escalate it to Microsoft Support. Include the connector name, timestamps,
bucket and prefix, encryption type, affected object sizes, and whether
historical ingestion was running.

## Safety and cost

- Deploy only in an approved sandbox or test account.
- The synthetic object contains no customer data.
- Resources are encrypted and block public access.
- The lab incurs small S3, SQS, and CloudFormation-related usage charges until
  it is removed.
- Always run `./scripts/teardown.sh` when the demonstration is complete.
