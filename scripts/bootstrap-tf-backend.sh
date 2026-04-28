#!/usr/bin/env bash
#
# bootstrap-tf-backend.sh
#
# Idempotently bootstrap the S3 bucket + DynamoDB table that hold
# Terraform remote state for this demo. Runs once per AWS account.
#
# Created (idempotent — safe to re-run):
#   - S3 bucket  `<prefix>-<account-id>` with:
#       * versioning enabled
#       * default encryption (AES256 / SSE-S3)
#       * public access fully blocked
#   - DynamoDB table `<prefix>-tflock` with:
#       * primary key `LockID` (string)
#       * pay-per-request billing
#
# After running, terraform/backend.tf and terraform/prereqs/backend.tf can
# `terraform init` against these resources and any teammate with sandbox
# SSO access can plan/apply from their own laptop. DynamoDB lock prevents
# concurrent applies stepping on each other.
#
# Usage:
#   source .env && scripts/bootstrap-tf-backend.sh
#
# Or:
#   scripts/bootstrap-tf-backend.sh --aws-profile sandbox --aws-region us-east-1
#
# Flags (env-var fallbacks in parens):
#   --aws-profile NAME    AWS CLI profile (env AWS_PROFILE)
#   --aws-region REGION   env AWS_REGION; default us-east-1
#   --prefix NAME         resource-name prefix (default
#                         "tfstate-coder-demo-aigov-rhsummit-2026")
#
# Requires: aws CLI v2.

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-us-east-1}"
PREFIX="${PREFIX:-tfstate-coder-demo-aigov-rhsummit-2026}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --aws-profile) AWS_PROFILE="$2"; shift 2 ;;
    --aws-region)  AWS_REGION="$2"; shift 2 ;;
    --prefix)      PREFIX="$2"; shift 2 ;;
    -h|--help)     sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

command -v aws >/dev/null || { echo "ERROR: aws CLI not on PATH." >&2; exit 1; }

ACCOUNT_ID="$(aws --profile "$AWS_PROFILE" sts get-caller-identity \
  --query Account --output text 2>/dev/null)" \
  || { echo "ERROR: profile '$AWS_PROFILE' not authenticated. Try: aws sso login --profile $AWS_PROFILE" >&2; exit 1; }

BUCKET="${PREFIX}-${ACCOUNT_ID}"
LOCK_TABLE="${PREFIX}-tflock"

echo "==========================================================="
echo "  Account     : $ACCOUNT_ID"
echo "  Region      : $AWS_REGION"
echo "  S3 bucket   : s3://$BUCKET"
echo "  Lock table  : $LOCK_TABLE"
echo "==========================================================="
echo

###############################################################################
# S3 bucket
###############################################################################

echo "==> Looking up S3 bucket s3://${BUCKET}..."

if aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3api head-bucket \
     --bucket "$BUCKET" 2>/dev/null; then
  echo "    found existing — skipping create."
else
  echo "    not found — creating..."
  if [ "$AWS_REGION" = "us-east-1" ]; then
    # us-east-1 is the only region where you must NOT pass LocationConstraint
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3api create-bucket \
      --bucket "$BUCKET"
  else
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3api create-bucket \
      --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION"
  fi
  echo "    created."
fi

echo "==> Enabling bucket versioning..."
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

echo "==> Enabling default encryption (AES256)..."
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]
  }'

echo "==> Blocking all public access..."
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

###############################################################################
# DynamoDB table for state locking
###############################################################################

echo "==> Looking up DynamoDB table $LOCK_TABLE..."

if aws --profile "$AWS_PROFILE" --region "$AWS_REGION" dynamodb describe-table \
     --table-name "$LOCK_TABLE" >/dev/null 2>&1; then
  echo "    found existing — skipping create."
else
  echo "    not found — creating..."
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" dynamodb create-table \
    --table-name "$LOCK_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=Project,Value=demo-aigov-rhaiis-rhsummit-2026 Key=Purpose,Value=terraform-state-lock \
    >/dev/null
  echo "    waiting for ACTIVE state..."
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" dynamodb wait table-exists \
    --table-name "$LOCK_TABLE"
  echo "    created."
fi

###############################################################################
# Print backend config for verification
###############################################################################

cat <<EOF

==========================================================
Backend ready. terraform/backend.tf and terraform/prereqs/backend.tf
should reference these values (committed in this repo):

  bucket         = "$BUCKET"
  region         = "$AWS_REGION"
  dynamodb_table = "$LOCK_TABLE"
  encrypt        = true

Per-config keys (set in each backend.tf):
  cluster TF       key = "cluster/terraform.tfstate"
  prereqs TF       key = "prereqs/terraform.tfstate"

To migrate existing local state into the bucket:
  cd terraform/prereqs && terraform init -migrate-state
  cd terraform         && terraform init -migrate-state

For a fresh teammate (no prior local state):
  cd terraform/prereqs && terraform init
  cd terraform         && terraform init
==========================================================
EOF
