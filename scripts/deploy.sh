#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_prerequisites

echo "Deploying intentionally incomplete permissions to account:"
aws sts get-caller-identity --query "{Account:Account,Arn:Arn}" --output table
echo "Region: ${AWS_REGION}"
echo "Stack:  ${STACK_NAME}"

aws cloudformation deploy \
  --stack-name "${STACK_NAME}" \
  --template-file "${TEMPLATE_FILE}" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    IncludeS3Permissions=false \
    TestPrefix="${TEST_PREFIX}" \
  --tags Purpose=MdcCloudTrailPermissionReproduction \
  --no-fail-on-empty-changeset \
  --no-cli-pager

bucket_name="$(stack_output BucketName)"
object_key="${TEST_PREFIX}/repro-$(date -u +%Y%m%dT%H%M%SZ).json"
record_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

printf '{"Records":[{"eventVersion":"1.09","eventTime":"%s","eventSource":"repro.example","eventName":"SyntheticCloudTrailRecord"}]}\n' "${record_time}" |
  aws s3 cp - "s3://${bucket_name}/${object_key}" \
    --sse AES256 \
    --content-type application/json \
    --no-progress

aws cloudformation update-termination-protection \
  --stack-name "${STACK_NAME}" \
  --no-enable-termination-protection >/dev/null 2>&1 || true

echo
echo "Broken state deployed."
echo "Bucket: ${bucket_name}"
echo "Object: ${object_key}"
echo "Next:   ./scripts/test-access.sh denied"

