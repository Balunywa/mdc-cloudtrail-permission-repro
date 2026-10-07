#!/usr/bin/env bash

set -Eeuo pipefail

STACK_NAME="${STACK_NAME:-mdc-cloudtrail-permission-repro}"
TEST_PREFIX="${TEST_PREFIX:-AWSLogs/repro/CloudTrail}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_FILE="${REPO_ROOT}/infrastructure/template.json"

if [[ -z "${AWS_REGION:-}" ]]; then
  AWS_REGION="${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}"
fi
AWS_REGION="${AWS_REGION:-us-east-2}"
export AWS_REGION

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

require_prerequisites() {
  require_command aws
  aws sts get-caller-identity --output json >/dev/null
}

stack_output() {
  local key="$1"
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue | [0]" \
    --output text
}

assume_repro_role() {
  local role_arn="$1"
  read -r ASSUMED_ACCESS_KEY ASSUMED_SECRET_KEY ASSUMED_SESSION_TOKEN < <(
    aws sts assume-role \
      --role-arn "${role_arn}" \
      --role-session-name "mdc-permission-repro" \
      --duration-seconds 900 \
      --query "Credentials.[AccessKeyId,SecretAccessKey,SessionToken]" \
      --output text
  )
  export ASSUMED_ACCESS_KEY ASSUMED_SECRET_KEY ASSUMED_SESSION_TOKEN
}

as_repro_role() {
  AWS_ACCESS_KEY_ID="${ASSUMED_ACCESS_KEY}" \
  AWS_SECRET_ACCESS_KEY="${ASSUMED_SECRET_KEY}" \
  AWS_SESSION_TOKEN="${ASSUMED_SESSION_TOKEN}" \
  AWS_REGION="${AWS_REGION}" \
    "$@"
}

