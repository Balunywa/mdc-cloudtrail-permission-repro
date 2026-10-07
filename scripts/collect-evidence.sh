#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_prerequisites

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
evidence_dir="${REPO_ROOT}/.evidence/${timestamp}"
mkdir -p "${evidence_dir}"

role_name="$(stack_output RoleName)"
queue_url="$(stack_output QueueUrl)"
bucket_name="$(stack_output BucketName)"

aws sts get-caller-identity --output json > "${evidence_dir}/caller-identity.json"
aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --output json > "${evidence_dir}/stack.json"
aws iam list-role-policies \
  --role-name "${role_name}" \
  --output json > "${evidence_dir}/role-inline-policies.json"
aws sqs get-queue-attributes \
  --queue-url "${queue_url}" \
  --attribute-names All \
  --output json > "${evidence_dir}/queue-attributes.json"
aws s3api get-bucket-encryption \
  --bucket "${bucket_name}" \
  --output json > "${evidence_dir}/bucket-encryption.json"
aws s3api get-public-access-block \
  --bucket "${bucket_name}" \
  --output json > "${evidence_dir}/bucket-public-access-block.json"

for policy_name in $(
  aws iam list-role-policies \
    --role-name "${role_name}" \
    --query "PolicyNames[]" \
    --output text
); do
  aws iam get-role-policy \
    --role-name "${role_name}" \
    --policy-name "${policy_name}" \
    --output json > "${evidence_dir}/policy-${policy_name}.json"
done

echo "Evidence written to: ${evidence_dir}"

