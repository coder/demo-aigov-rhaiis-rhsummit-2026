#!/usr/bin/env bash
#
# verify-aws-access.sh
#
# Sanity-check the two AWS profiles this demo expects:
#   AWS_PROFILE_SANDBOX   — Account B (cluster lives here)
#   AWS_PROFILE_PARENT    — Account A (parent R53 zone). Optional.
#
# Runs sts:GetCallerIdentity + a couple of representative API calls per
# profile to confirm the principal has the perms the demo actually uses.
# Reports a green/red checklist and exits non-zero if anything's missing.
#
# Usage:
#   source .env             # sets AWS_PROFILE_SANDBOX / AWS_PROFILE_PARENT
#   scripts/verify-aws-access.sh
#
# Or pass profiles inline:
#   scripts/verify-aws-access.sh --sandbox myprofile [--parent otherprofile]
#
# Requires: aws CLI v2.

set -uo pipefail

SANDBOX="${AWS_PROFILE_SANDBOX:-}"
PARENT="${AWS_PROFILE_PARENT:-}"
REGION="${AWS_REGION:-us-east-1}"
PARENT_ZONE="${PARENT_ZONE:-coderdemo.io}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sandbox) SANDBOX="$2"; shift 2 ;;
    --parent)  PARENT="$2";  shift 2 ;;
    --region)  REGION="$2";  shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

command -v aws >/dev/null \
  || { echo "ERROR: aws CLI not on PATH." >&2; exit 1; }

if [[ -z "$SANDBOX" ]]; then
  echo "ERROR: AWS_PROFILE_SANDBOX is not set (and --sandbox flag not provided)." >&2
  echo "       Either source .env or pass --sandbox <profile-name>." >&2
  exit 1
fi

###############################################################################
# Helpers — print PASS/FAIL with a short description and capture failures
###############################################################################

FAIL_COUNT=0
SKIP_COUNT=0

PASS="\033[32m✓\033[0m"
FAIL="\033[31m✗\033[0m"
SKIP="\033[33m○\033[0m"
WARN="\033[33m!\033[0m"

WARN_COUNT=0

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf "  %b %s\n" "$PASS" "$label"
  else
    printf "  %b %s\n" "$FAIL" "$label"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  fi
}

# soft-check: failures emit a warning + remediation hint, do NOT count
# against exit status. Use for things that are recoverable later (Bedrock
# region activation) or that the cluster install path doesn't actually
# need at install time.
soft_check() {
  local label="$1" hint="$2"; shift 2
  if "$@" >/dev/null 2>&1; then
    printf "  %b %s\n" "$PASS" "$label"
  else
    printf "  %b %s  (%s)\n" "$WARN" "$label" "$hint"
    WARN_COUNT=$(( WARN_COUNT + 1 ))
  fi
}

skip() {
  local label="$1" reason="$2"
  printf "  %b %s  (%s)\n" "$SKIP" "$label" "$reason"
  SKIP_COUNT=$(( SKIP_COUNT + 1 ))
}

###############################################################################
# Sandbox profile
###############################################################################

printf '\n=== Sandbox profile (%s) — region %s ===\n\n' "$SANDBOX" "$REGION"

if ! aws --profile "$SANDBOX" sts get-caller-identity >/dev/null 2>&1; then
  echo "  $(printf '%b' "$FAIL") sts:GetCallerIdentity — profile not configured or creds expired"
  echo
  echo "  Hints:"
  echo "    - 'aws sso login --profile $SANDBOX'   if you use Identity Center"
  echo "    - 'aws configure --profile $SANDBOX'   if you use static keys"
  echo "  See docs/aws-setup.md §1 for the full walkthrough."
  exit 2
fi

ACCOUNT_ID=$(aws --profile "$SANDBOX" sts get-caller-identity --query Account --output text)
ARN=$(aws --profile "$SANDBOX" sts get-caller-identity --query Arn --output text)
printf "  %b sts:GetCallerIdentity  (Account: %s)\n" "$PASS" "$ACCOUNT_ID"
printf "    principal: %s\n\n" "$ARN"

# These map to the calls TF + scripts make most often. iam:GetUser is
# intentionally NOT here — SSO assumes a federated role, not an IAM user,
# so iam:GetUser always returns NoSuchEntity even with AdministratorAccess.
# sts:GetCallerIdentity (already passed above) is the correct "whoami"
# for an SSO session.
check "ec2:DescribeVpcs"                         aws --profile "$SANDBOX" --region "$REGION" ec2 describe-vpcs --max-items 1
check "ec2:DescribeSubnets"                      aws --profile "$SANDBOX" --region "$REGION" ec2 describe-subnets --max-items 1
check "iam:ListUsers"                            aws --profile "$SANDBOX" iam list-users --max-items 1
check "route53:ListHostedZones"                  aws --profile "$SANDBOX" route53 list-hosted-zones --max-items 1
check "service-quotas:GetServiceQuota (vCPU)"    aws --profile "$SANDBOX" --region "$REGION" service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A
check "service-quotas:list-history (vCPU)"       aws --profile "$SANDBOX" --region "$REGION" service-quotas list-requested-service-quota-change-history-by-quota --service-code ec2 --quota-code L-1216C47A
check "elasticloadbalancing:DescribeLoadBalancers" aws --profile "$SANDBOX" --region "$REGION" elbv2 describe-load-balancers --max-items 1
check "s3:ListAllMyBuckets"                      aws --profile "$SANDBOX" s3api list-buckets

# Bedrock is consumed by AI Gateway at runtime (post-cluster). AWS retired
# the per-model approval page in late 2025; serverless models auto-enable
# on first invocation. Failure here usually just means the principal
# hasn't yet invoked any Bedrock model in this region (one bedrock-runtime
# invoke-model fixes it; first-time Anthropic users may also see a use-case
# form). Does not block cluster install.
soft_check "bedrock:ListFoundationModels" \
  "soft — Bedrock not yet invoked in this region; first invoke auto-enables. Anthropic first-time users may need to fill a 1-page use-case form." \
  aws --profile "$SANDBOX" --region "$REGION" bedrock list-foundation-models --max-results 1

###############################################################################
# Parent profile (optional)
###############################################################################

printf '\n=== Parent profile (%s) ===\n\n' "${PARENT:-<not set>}"

if [[ -z "$PARENT" ]]; then
  skip "Parent profile checks" "AWS_PROFILE_PARENT not set — handoff mode (bootstrap-r53-delegation.sh will emit JSON)"
else
  if ! aws --profile "$PARENT" sts get-caller-identity >/dev/null 2>&1; then
    printf "  %b sts:GetCallerIdentity — profile not configured or creds expired\n" "$FAIL"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  else
    PARENT_ACCOUNT=$(aws --profile "$PARENT" sts get-caller-identity --query Account --output text)
    PARENT_ARN=$(aws --profile "$PARENT" sts get-caller-identity --query Arn --output text)
    printf "  %b sts:GetCallerIdentity  (Account: %s)\n" "$PASS" "$PARENT_ACCOUNT"
    printf "    principal: %s\n\n" "$PARENT_ARN"

    check "route53:ListHostedZonesByName"          aws --profile "$PARENT" route53 list-hosted-zones-by-name --dns-name "${PARENT_ZONE}." --max-items 1

    # If the parent zone exists, confirm we can read records (a soft proxy for
    # "we'll be able to UPSERT an NS record later"). list-resource-record-sets
    # is read; ChangeResourceRecordSets is what's actually needed for the NS
    # delegation, but you can't safely test that without making a real change.
    PARENT_ZONE_ID=$(aws --profile "$PARENT" route53 list-hosted-zones-by-name \
      --dns-name "${PARENT_ZONE}." --max-items 1 \
      --query "HostedZones[?Name=='${PARENT_ZONE}.'].Id | [0]" \
      --output text 2>/dev/null || echo "None")

    if [[ "$PARENT_ZONE_ID" != "None" && -n "$PARENT_ZONE_ID" ]]; then
      printf "    parent zone found: %s (id: %s)\n" "$PARENT_ZONE" "$PARENT_ZONE_ID"
      check "route53:ListResourceRecordSets on parent zone" \
        aws --profile "$PARENT" route53 list-resource-record-sets --hosted-zone-id "$PARENT_ZONE_ID" --max-items 1
    else
      printf "  %b parent zone %s not found in this account\n" "$FAIL" "$PARENT_ZONE"
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fi
  fi
fi

###############################################################################
# Summary
###############################################################################

echo
echo "==========================================================="
if (( FAIL_COUNT == 0 )); then
  printf "%b  All required checks passed (%d skipped, %d soft-warning).\n" \
    "$PASS" "$SKIP_COUNT" "$WARN_COUNT"
  echo "    You're ready to run scripts/bootstrap-r53-delegation.sh and"
  echo "    scripts/aws-quota-bootstrap.sh, then 'cd terraform && terraform apply'."
  if (( WARN_COUNT > 0 )); then
    echo
    echo "    Soft warnings are recoverable later (e.g., Bedrock region"
    echo "    activation is a one-time AWS console click, not blocking)."
  fi
  exit 0
else
  printf "%b  %d check(s) failed (%d skipped, %d soft-warning).\n" \
    "$FAIL" "$FAIL_COUNT" "$SKIP_COUNT" "$WARN_COUNT"
  echo "    See docs/aws-setup.md §2 (sandbox perms) or §3b (parent perms)."
  echo "    docs/aws-creds.md explains *why* each permission is needed."
  exit 3
fi
