#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_prerequisites

if ! aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --output json >/dev/null 2>&1; then
  echo "Stack ${STACK_NAME} does not exist; nothing to remove."
  exit 0
fi

bucket_name="$(stack_output BucketName)"

echo "Emptying s3://${bucket_name}/"
aws s3 rm "s3://${bucket_name}" --recursive --only-show-errors

echo "Deleting stack ${STACK_NAME}"
aws cloudformation delete-stack --stack-name "${STACK_NAME}"
aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}"

echo "Teardown complete."

