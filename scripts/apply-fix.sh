#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_prerequisites

aws cloudformation deploy \
  --stack-name "${STACK_NAME}" \
  --template-file "${TEMPLATE_FILE}" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    IncludeS3Permissions=true \
    TestPrefix="${TEST_PREFIX}" \
  --tags Purpose=MdcCloudTrailPermissionReproduction \
  --no-fail-on-empty-changeset \
  --no-cli-pager

echo "Least-privilege S3 permissions applied."
echo "Next: ./scripts/test-access.sh success"

