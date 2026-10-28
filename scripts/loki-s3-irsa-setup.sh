#!/usr/bin/env bash
# Provision AWS S3 + IRSA for Loki (coder-observability) on the RH Summit
# 2026 re-install cluster (account 342934376218, us-east-1).
#
# Replaces the gated upstream MinIO image: Loki writes chunks/ruler to a real
# S3 bucket, authenticating via IRSA (the loki ServiceAccount assumes an IAM
# role through the cluster's OIDC provider — no static keys).
#
# Requires: valid admin creds for 342934376218 in $AWS_PROFILE (default: default)
set -euo pipefail

PROFILE="${AWS_PROFILE:-default}"
REGION="us-east-1"
NS="coder-observability"
SA="loki"
BUCKET="${BUCKET:-coder-rhsummit-loki-342934376218}"
ROLE="cluster-coder-loki"
POLICY="cluster-coder-loki-s3"
ISSUER_HOST="cluster-rhsummit-coderdemo-io-oidc.s3.us-east-1.amazonaws.com"

ACCT="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
echo "account=$ACCT bucket=$BUCKET region=$REGION"

OIDC_ARN="$(aws iam list-open-id-connect-providers --profile "$PROFILE" \
  --query "OpenIDConnectProviderList[?contains(Arn, '$ISSUER_HOST')].Arn | [0]" --output text)"
[ "$OIDC_ARN" != "None" ] && [ -n "$OIDC_ARN" ] || { echo "OIDC provider for $ISSUER_HOST not found" >&2; exit 1; }
echo "oidc=$OIDC_ARN"

# 1) S3 bucket (idempotent) — us-east-1 needs no LocationConstraint
if ! aws s3api head-bucket --bucket "$BUCKET" --profile "$PROFILE" 2>/dev/null; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" --profile "$PROFILE"
fi
aws s3api put-public-access-block --bucket "$BUCKET" --profile "$PROFILE" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" --profile "$PROFILE" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# 2) IAM policy (scoped to this bucket)
POLICY_DOC=$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"LokiBucket","Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":"arn:aws:s3:::$BUCKET"},
 {"Sid":"LokiObjects","Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":"arn:aws:s3:::$BUCKET/*"}
]}
JSON
)
POLICY_ARN="arn:aws:iam::$ACCT:policy/$POLICY"
if ! aws iam get-policy --policy-arn "$POLICY_ARN" --profile "$PROFILE" >/dev/null 2>&1; then
  aws iam create-policy --policy-name "$POLICY" --policy-document "$POLICY_DOC" --profile "$PROFILE" >/dev/null
else
  VER=$(aws iam create-policy-version --policy-arn "$POLICY_ARN" --policy-document "$POLICY_DOC" --set-as-default --profile "$PROFILE" --query 'PolicyVersion.VersionId' --output text 2>/dev/null || true)
  echo "policy updated (version $VER)"
fi

# 3) IAM role with IRSA trust (aud=sts.amazonaws.com, sub=the loki SA)
TRUST=$(cat <<JSON
{"Version":"2012-10-17","Statement":[{
 "Effect":"Allow",
 "Principal":{"Federated":"$OIDC_ARN"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{"StringEquals":{
   "$ISSUER_HOST:aud":"sts.amazonaws.com",
   "$ISSUER_HOST:sub":"system:serviceaccount:$NS:$SA"
 }}
}]}
JSON
)
if ! aws iam get-role --role-name "$ROLE" --profile "$PROFILE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" --profile "$PROFILE" >/dev/null
else
  aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "$TRUST" --profile "$PROFILE"
fi
aws iam attach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN" --profile "$PROFILE"

ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --profile "$PROFILE" --query 'Role.Arn' --output text)"
echo
echo "DONE."
echo "ROLE_ARN=$ROLE_ARN"
echo "BUCKET=$BUCKET"
echo "Set loki.serviceAccount.annotations.eks.amazonaws.com/role-arn=$ROLE_ARN"
