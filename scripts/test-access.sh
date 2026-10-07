#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

expected="${1:-}"
if [[ "${expected}" != "denied" && "${expected}" != "success" ]]; then
  echo "Usage: $0 <denied|success>" >&2
  exit 2
fi

require_prerequisites

role_arn="$(stack_output RoleArn)"
queue_url="$(stack_output QueueUrl)"
bucket_name="$(stack_output BucketName)"
prefix="$(stack_output TestPrefix)"
object_key="$(
  aws s3api list-objects-v2 \
    --bucket "${bucket_name}" \
    --prefix "${prefix}/" \
    --query "sort_by(Contents,&LastModified)[-1].Key" \
    --output text
)"

if [[ -z "${object_key}" || "${object_key}" == "None" ]]; then
  echo "ERROR: no test object found under s3://${bucket_name}/${prefix}/" >&2
  exit 1
fi

assume_repro_role "${role_arn}"

as_repro_role aws sqs get-queue-attributes \
  --queue-url "${queue_url}" \
  --attribute-names ApproximateNumberOfMessages \
  --output json >/dev/null
echo "PASS: the role can read SQS queue attributes."

download_file="$(mktemp)"
error_file="$(mktemp)"
trap 'rm -f "${download_file}" "${error_file}"' EXIT

set +e
as_repro_role aws s3api get-object \
  --bucket "${bucket_name}" \
  --key "${object_key}" \
  "${download_file}" \
  --no-cli-pager > /dev/null 2>"${error_file}"
status=$?
set -e

if [[ "${expected}" == "denied" ]]; then
  if [[ ${status} -eq 0 ]]; then
    echo "FAIL: S3 download succeeded, but AccessDenied was expected." >&2
    exit 1
  fi
  if ! grep -qi "AccessDenied" "${error_file}"; then
    echo "FAIL: S3 download failed for an unexpected reason:" >&2
    cat "${error_file}" >&2
    exit 1
  fi
  echo "PASS: S3 access was denied as expected before the fix."
  cat "${error_file}"
  exit 0
fi

if [[ ${status} -ne 0 ]]; then
  echo "FAIL: S3 download remained unavailable after the fix:" >&2
  cat "${error_file}" >&2
  exit 1
fi

if ! grep -q "SyntheticCloudTrailRecord" "${download_file}"; then
  echo "FAIL: downloaded object did not contain the expected synthetic record." >&2
  exit 1
fi

echo "PASS: the same role downloaded the same object after the fix."
echo "Object: s3://${bucket_name}/${object_key}"
echo "Bytes:  $(wc -c < "${download_file}" | tr -d ' ')"

