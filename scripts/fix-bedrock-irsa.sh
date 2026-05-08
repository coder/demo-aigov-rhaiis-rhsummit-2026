#!/usr/bin/env bash
set -euo pipefail

# fix-bedrock-irsa.sh — Ensures the cluster-coder-bedrock IAM role exists
# with the correct OIDC trust policy and Bedrock permissions.
#
# PROBLEM: The pod-identity-webhook injects IRSA credentials into the
# coder-server pods, but AssumeRoleWithWebIdentity returns AccessDenied.
# The IAM role's trust policy is either missing or misconfigured (likely
# created with the old sts:AssumeRole pattern before the STS/IRSA refactor).
#
# Run this after refreshing AWS credentials:
#   env -u AWS_ENDPOINT_URL aws sso login --profile ocp-deploy-acct
#   ./scripts/fix-bedrock-irsa.sh
#
# Or from any shell with valid ocp-deploy-acct credentials:
#   AWS_PROFILE=ocp-deploy-acct ./scripts/fix-bedrock-irsa.sh

ROLE_NAME="cluster-coder-bedrock"
ROLE_PATH="/demo/"
OIDC_PROVIDER_URL="cluster-rhsummit-coderdemo-io-oidc.s3.us-east-1.amazonaws.com"
ACCOUNT_ID="342934376218"
SA_SUB="system:serviceaccount:coder:coder-server"
REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-ocp-deploy-acct}"

if [[ "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $0 [--dry-run]

Ensures the cluster-coder-bedrock IAM role has the correct OIDC trust
policy for the coder-server ServiceAccount. Requires valid AWS credentials
for the ocp-deploy-acct profile.

Options:
  --dry-run   Print the trust policy and permissions without applying
  --help      Show this help
EOF
  exit 0
fi

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Trust policy: allow the coder-server SA to assume this role via OIDC
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCoderSA",
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER_URL}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER_URL}:sub": "${SA_SUB}",
          "${OIDC_PROVIDER_URL}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)

# Bedrock invoke permissions
BEDROCK_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockInvoke",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:Converse",
        "bedrock:ConverseStream",
        "bedrock:ListFoundationModels",
        "bedrock:GetFoundationModel",
        "bedrock:ListInferenceProfiles",
        "bedrock:GetInferenceProfile"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)

echo "==> Trust policy:"
echo "$TRUST_POLICY" | python3 -m json.tool
echo ""
echo "==> Bedrock permissions policy:"
echo "$BEDROCK_POLICY" | python3 -m json.tool
echo ""

if $DRY_RUN; then
  echo "[dry-run] Would update role ${ROLE_NAME} with the above policies."
  exit 0
fi

AWS_ARGS=(--region "$REGION" --profile "$PROFILE" --no-cli-pager)

# Check if role exists
if aws iam get-role --role-name "$ROLE_NAME" "${AWS_ARGS[@]}" &>/dev/null; then
  echo "==> Role ${ROLE_NAME} exists. Updating trust policy..."
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY" \
    "${AWS_ARGS[@]}"
  echo "    Trust policy updated."
else
  echo "==> Role ${ROLE_NAME} does not exist. Creating..."
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --path "$ROLE_PATH" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --tags "Key=Project,Value=demo-aigov-rhaiis-rhsummit-2026" "Key=ManagedBy,Value=script" \
    "${AWS_ARGS[@]}"
  echo "    Role created."
fi

# Ensure the inline policy is correct
echo "==> Putting inline policy 'bedrock-invoke'..."
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "bedrock-invoke" \
  --policy-document "$BEDROCK_POLICY" \
  "${AWS_ARGS[@]}"
echo "    Policy attached."

echo ""
echo "==> Done. Verify from inside the cluster:"
echo "    oc exec -n coder <coder-pod> -- sh -c 'export HOME=/tmp && aws sts get-caller-identity --region us-east-1'"
echo ""
echo "    If pods were already running, they already have the token."
echo "    The fix is immediate — no pod restart needed."
