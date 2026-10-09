#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

apply=false
if [[ "${1:-}" == "--apply" ]]; then
  apply=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--apply]" >&2
  exit 2
fi

required_variables=(
  DEFENDER_ROLE_ARN
  CLOUDTRAIL_BUCKET_NAME
  CLOUDTRAIL_QUEUE_ARN
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "ERROR: required environment variable is not set: ${variable}" >&2
    exit 1
  fi
done

for command in aws jq; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: ${command}" >&2
    exit 1
  }
done

CLOUDTRAIL_PREFIX="${CLOUDTRAIL_PREFIX:-AWSLogs/}"
CONFIGURE_S3_NOTIFICATION="${CONFIGURE_S3_NOTIFICATION:-true}"
KMS_KEY_ARN="${KMS_KEY_ARN:-}"

if [[ "${DEFENDER_ROLE_ARN}" != arn:*:iam::*:role/* ]]; then
  echo "ERROR: DEFENDER_ROLE_ARN is not an IAM role ARN." >&2
  exit 1
fi
if [[ "${CLOUDTRAIL_QUEUE_ARN}" != arn:*:sqs:*:*:* ]]; then
  echo "ERROR: CLOUDTRAIL_QUEUE_ARN is not an SQS queue ARN." >&2
  exit 1
fi
if [[ "${CONFIGURE_S3_NOTIFICATION}" != "true" && "${CONFIGURE_S3_NOTIFICATION}" != "false" ]]; then
  echo "ERROR: CONFIGURE_S3_NOTIFICATION must be true or false." >&2
  exit 1
fi

IFS=: read -r arn_literal queue_partition queue_service queue_region queue_account queue_name <<<"${CLOUDTRAIL_QUEUE_ARN}"
caller_account="$(aws sts get-caller-identity --query Account --output text)"

if [[ "${arn_literal}" != "arn" || "${queue_service}" != "sqs" ]]; then
  echo "ERROR: unable to parse CLOUDTRAIL_QUEUE_ARN." >&2
  exit 1
fi
if [[ "${caller_account}" != "${queue_account}" ]]; then
  echo "ERROR: sign into the SQS resource-owning account ${queue_account} before running this script." >&2
  echo "Current account: ${caller_account}" >&2
  exit 1
fi

queue_url="$(
  aws sqs get-queue-url \
    --queue-name "${queue_name}" \
    --queue-owner-aws-account-id "${queue_account}" \
    --region "${queue_region}" \
    --query QueueUrl \
    --output text
)"

bucket_arn="arn:${queue_partition}:s3:::${CLOUDTRAIL_BUCKET_NAME}"
source_account="${caller_account}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="${REPO_ROOT}/.evidence/cross-account-policy-backups/${timestamp}"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

mkdir -p "${backup_dir}"

queue_policy_backup="${backup_dir}/sqs-policy.json"
bucket_policy_backup="${backup_dir}/s3-bucket-policy.json"
notification_backup="${backup_dir}/s3-notification.json"
queue_policy_file="${backup_dir}/proposed-sqs-policy.json"
bucket_policy_file="${backup_dir}/proposed-s3-bucket-policy.json"
notification_file="${backup_dir}/proposed-s3-notification.json"

if [[ -n "${KMS_KEY_ARN}" ]]; then
  IFS=: read -r kms_arn_literal kms_partition kms_service kms_region kms_account kms_resource <<<"${KMS_KEY_ARN}"
  if [[ "${kms_arn_literal}" != "arn" || "${kms_service}" != "kms" ]]; then
    echo "ERROR: unable to parse KMS_KEY_ARN." >&2
    exit 1
  fi
  if [[ "${caller_account}" != "${kms_account}" ]]; then
    echo "ERROR: KMS key ${KMS_KEY_ARN} is owned by account ${kms_account}." >&2
    echo "Run the KMS policy update while signed into that account." >&2
    exit 1
  fi
fi

queue_policy="$(
  aws sqs get-queue-attributes \
    --queue-url "${queue_url}" \
    --attribute-names Policy \
    --region "${queue_region}" \
    --query "Attributes.Policy" \
    --output text
)"
if [[ -z "${queue_policy}" || "${queue_policy}" == "None" ]]; then
  queue_policy='{"Version":"2012-10-17","Statement":[]}'
fi
printf '%s\n' "${queue_policy}" | jq . > "${queue_policy_backup}"

jq \
  --arg role "${DEFENDER_ROLE_ARN}" \
  --arg queue "${CLOUDTRAIL_QUEUE_ARN}" \
  --arg bucket "${bucket_arn}" \
  --arg account "${source_account}" \
  '
  .Version = (.Version // "2012-10-17")
  | .Statement = ((.Statement // [])
      | map(select(.Sid != "AllowDefenderCloudTrailConsumer"
                   and .Sid != "AllowCloudTrailBucketNotifications"))
      + [
          {
            "Sid": "AllowDefenderCloudTrailConsumer",
            "Effect": "Allow",
            "Principal": {"AWS": $role},
            "Action": [
              "sqs:ChangeMessageVisibility",
              "sqs:DeleteMessage",
              "sqs:GetQueueAttributes",
              "sqs:GetQueueUrl",
              "sqs:ReceiveMessage"
            ],
            "Resource": $queue
          },
          {
            "Sid": "AllowCloudTrailBucketNotifications",
            "Effect": "Allow",
            "Principal": {"Service": "s3.amazonaws.com"},
            "Action": "sqs:SendMessage",
            "Resource": $queue,
            "Condition": {
              "ArnEquals": {"aws:SourceArn": $bucket},
              "StringEquals": {"aws:SourceAccount": $account}
            }
          }
        ])
  ' "${queue_policy_backup}" > "${queue_policy_file}"

set +e
aws s3api get-bucket-policy \
  --bucket "${CLOUDTRAIL_BUCKET_NAME}" \
  --query Policy \
  --output text > "${work_dir}/bucket-policy-raw.txt" 2>"${work_dir}/bucket-policy-error.txt"
bucket_policy_status=$?
set -e

if [[ ${bucket_policy_status} -eq 0 ]]; then
  jq . "${work_dir}/bucket-policy-raw.txt" > "${bucket_policy_backup}"
elif grep -q "NoSuchBucketPolicy" "${work_dir}/bucket-policy-error.txt"; then
  printf '%s\n' '{"Version":"2012-10-17","Statement":[]}' > "${bucket_policy_backup}"
else
  cat "${work_dir}/bucket-policy-error.txt" >&2
  exit "${bucket_policy_status}"
fi

jq \
  --arg role "${DEFENDER_ROLE_ARN}" \
  --arg bucket "${bucket_arn}" \
  --arg objects "${bucket_arn}/${CLOUDTRAIL_PREFIX}*" \
  '
  .Version = (.Version // "2012-10-17")
  | .Statement = ((.Statement // [])
      | map(select(.Sid != "AllowDefenderCloudTrailBucketMetadata"
                   and .Sid != "AllowDefenderCloudTrailObjectRead"))
      + [
          {
            "Sid": "AllowDefenderCloudTrailBucketMetadata",
            "Effect": "Allow",
            "Principal": {"AWS": $role},
            "Action": [
              "s3:GetBucketLocation",
              "s3:ListBucket"
            ],
            "Resource": $bucket
          },
          {
            "Sid": "AllowDefenderCloudTrailObjectRead",
            "Effect": "Allow",
            "Principal": {"AWS": $role},
            "Action": "s3:GetObject",
            "Resource": $objects
          }
        ])
  ' "${bucket_policy_backup}" > "${bucket_policy_file}"

aws s3api get-bucket-notification-configuration \
  --bucket "${CLOUDTRAIL_BUCKET_NAME}" > "${notification_backup}"

jq \
  --arg queue "${CLOUDTRAIL_QUEUE_ARN}" \
  --arg prefix "${CLOUDTRAIL_PREFIX}" \
  '
  .QueueConfigurations = ((.QueueConfigurations // [])
      | map(select(.Id != "MdcDefenderCloudTrail"))
      + [
          {
            "Id": "MdcDefenderCloudTrail",
            "QueueArn": $queue,
            "Events": ["s3:ObjectCreated:*"],
            "Filter": {
              "Key": {
                "FilterRules": [
                  {"Name": "prefix", "Value": $prefix}
                ]
              }
            }
          }
        ])
  ' "${notification_backup}" > "${notification_file}"

if [[ -n "${KMS_KEY_ARN}" ]]; then
  kms_policy_backup="${backup_dir}/kms-key-policy.json"
  kms_policy_file="${backup_dir}/proposed-kms-key-policy.json"
  aws kms get-key-policy \
    --key-id "${KMS_KEY_ARN}" \
    --policy-name default \
    --region "${kms_region}" \
    --query Policy \
    --output text | jq . > "${kms_policy_backup}"

  jq \
    --arg role "${DEFENDER_ROLE_ARN}" \
    '
    .Statement = ((.Statement // [])
        | map(select(.Sid != "AllowDefenderCloudTrailDecrypt"))
        + [
            {
              "Sid": "AllowDefenderCloudTrailDecrypt",
              "Effect": "Allow",
              "Principal": {"AWS": $role},
              "Action": [
                "kms:Decrypt",
                "kms:DescribeKey"
              ],
              "Resource": "*"
            }
          ])
    ' "${kms_policy_backup}" > "${kms_policy_file}"
fi

echo "Current account:       ${caller_account}"
echo "Defender role:         ${DEFENDER_ROLE_ARN}"
echo "CloudTrail bucket:     ${CLOUDTRAIL_BUCKET_NAME}"
echo "CloudTrail prefix:     ${CLOUDTRAIL_PREFIX}"
echo "Dedicated SQS queue:   ${CLOUDTRAIL_QUEUE_ARN}"
echo "Configure notification:${CONFIGURE_S3_NOTIFICATION}"
echo "Policy backups:        ${backup_dir}"

if [[ "${apply}" != "true" ]]; then
  echo
  echo "Dry run only. Review the generated policy files:"
  echo "  ${queue_policy_file}"
  echo "  ${bucket_policy_file}"
  echo "  ${notification_file}"
  if [[ -n "${KMS_KEY_ARN}" ]]; then
    echo "  ${kms_policy_file}"
  fi
  echo "Run again with --apply to make the changes."
  exit 0
fi

aws sqs set-queue-attributes \
  --queue-url "${queue_url}" \
  --attributes "Policy=$(jq -c . "${queue_policy_file}")" \
  --region "${queue_region}"

aws s3api put-bucket-policy \
  --bucket "${CLOUDTRAIL_BUCKET_NAME}" \
  --policy "file://${bucket_policy_file}"

if [[ "${CONFIGURE_S3_NOTIFICATION}" == "true" ]]; then
  aws s3api put-bucket-notification-configuration \
    --bucket "${CLOUDTRAIL_BUCKET_NAME}" \
    --notification-configuration "file://${notification_file}"
fi

if [[ -n "${KMS_KEY_ARN}" ]]; then
  aws kms put-key-policy \
    --key-id "${KMS_KEY_ARN}" \
    --policy-name default \
    --policy "file://${kms_policy_file}" \
    --region "${kms_region}"
fi

echo "Cross-account CloudTrail resource policies updated successfully."
echo "Allow up to three hours for Defender for Cloud connector health to refresh."
