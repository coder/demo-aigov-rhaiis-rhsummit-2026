#!/usr/bin/env bash
#
# scripts/catalog-preflight.sh
#
# Single-shot pre-deployment readiness check for a fresh AWS account.
# Runs before `terraform apply` so the deployer learns about missing
# creds / quotas / DNS delegation / GitHub-side prerequisites in
# seconds instead of 30 minutes into install.
#
# Exits non-zero if any check fails. Prints a green/red checklist so
# the operator can see what's missing at a glance.
#
# Companion to scripts/catalog-postdeploy-smoke.sh.
#
# Usage:
#   ./scripts/catalog-preflight.sh
#
# Optional env (read from terraform/terraform.tfvars if not in env):
#   AWS_PROFILE          AWS CLI profile to use (default: default)
#   AWS_REGION           Target region (default: us-east-1)
#   CLUSTER_NAME         Short cluster id (default: demo)
#   BASE_DOMAIN          Parent DNS zone you control (e.g. example.com)
#   GITHUB_ORG           Org for OAuth restriction (e.g. demo-rhsummit-users)
#   GITHUB_TOKEN         Optional GitHub PAT for org-existence + scope checks
#   ENABLE_GPU           "true" or "false" (default: false) — adjusts quota expectations
#   PULL_SECRET_PATH     OCP pull secret path (default: ~/.openshift/pull-secret.json)
#   SSH_PUBKEY_PATH      SSH key for bootstrap node (default: ~/.ssh/id_ed25519.pub)
#
# Requires: aws, jq, curl, python3. Optional: terraform, gh, dig.

set -uo pipefail

# ---------- Inputs ---------------------------------------------------

# If terraform/terraform.tfvars exists, source values from it for any
# vars not already in env. Light parse — only handles `key = "value"` lines.
TFVARS_FILE="${TFVARS_FILE:-$(dirname "$0")/../terraform/terraform.tfvars}"
read_tfvar() {
  local key=$1
  [[ -f "$TFVARS_FILE" ]] || return
  python3 -c "
import re, sys
with open('$TFVARS_FILE') as f:
    for line in f:
        m = re.match(r'^\s*$key\s*=\s*\"?([^\"]*)\"?\s*(#.*)?$', line)
        if m:
            print(m.group(1))
            sys.exit(0)
" 2>/dev/null || true
}

AWS_PROFILE="${AWS_PROFILE:-$(read_tfvar aws_profile)}"
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-$(read_tfvar aws_region)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-$(read_tfvar cluster_name)}"
CLUSTER_NAME="${CLUSTER_NAME:-demo}"
BASE_DOMAIN="${BASE_DOMAIN:-$(read_tfvar base_domain)}"
GITHUB_ORG="${GITHUB_ORG:-}"
ENABLE_GPU="${ENABLE_GPU:-false}"
PULL_SECRET_PATH="${PULL_SECRET_PATH:-$(read_tfvar pull_secret_path)}"
PULL_SECRET_PATH="${PULL_SECRET_PATH:-$HOME/.openshift/pull-secret.json}"
SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH:-$(read_tfvar ssh_pubkey_path)}"
SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH:-$HOME/.ssh/id_ed25519.pub}"

# Allow tilde-expanded paths from .tfvars
PULL_SECRET_PATH="${PULL_SECRET_PATH/#~/$HOME}"
SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH/#~/$HOME}"

# ---------- Output helpers ------------------------------------------

if [[ -t 1 ]]; then
  G="\033[32m"; R="\033[31m"; Y="\033[33m"; B="\033[1m"; N="\033[0m"
else
  G=""; R=""; Y=""; B=""; N=""
fi
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() { echo -e "  ${G}✓${N} $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo -e "  ${R}✗${N} $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
warn() { echo -e "  ${Y}!${N} $1"; WARN_COUNT=$((WARN_COUNT+1)); }
section() { echo; echo -e "${B}== $1 ==${N}"; }

# ---------- Section 1: Local tooling ---------------------------------

section "Local tooling"

for t in aws jq curl python3; do
  if command -v "$t" >/dev/null; then
    pass "$t present ($(command -v "$t"))"
  else
    fail "$t not found on PATH"
  fi
done

for t in terraform openshift-install oc kubeseal helm gh dig; do
  if command -v "$t" >/dev/null; then
    pass "$t present ($(command -v "$t"))"
  else
    warn "$t not found on PATH (needed at later steps)"
  fi
done

# Versions of the must-have tools
if command -v aws >/dev/null; then
  ver=$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)
  if [[ "$ver" == 2.* ]]; then
    pass "aws CLI v$ver (need v2)"
  else
    fail "aws CLI v$ver — need v2 (v1 syntax differs)"
  fi
fi
if command -v terraform >/dev/null; then
  ver=$(terraform version -json 2>/dev/null | jq -r .terraform_version 2>/dev/null || terraform version | head -1 | awk '{print $2}' | tr -d v)
  if [[ "$ver" =~ ^1\.([6-9]|[1-9][0-9]) ]]; then
    pass "terraform v$ver (need 1.6+)"
  else
    warn "terraform v$ver — recommend 1.6+ (catalog state was authored against 1.6)"
  fi
fi
if command -v openshift-install >/dev/null; then
  ver=$(openshift-install version | head -1 | awk '{print $2}')
  case "$ver" in
    4.2[1-9].*|4.[3-9][0-9].*|[5-9].*.*)
      pass "openshift-install $ver" ;;
    *)
      warn "openshift-install $ver — repo targets 4.21+" ;;
  esac
fi

# ---------- Section 2: Local files ----------------------------------

section "Required input files"

if [[ -f "$PULL_SECRET_PATH" ]]; then
  if jq -e .auths "$PULL_SECRET_PATH" >/dev/null 2>&1; then
    pass "OpenShift pull secret at $PULL_SECRET_PATH (valid JSON, has .auths)"
  else
    fail "Pull secret at $PULL_SECRET_PATH is not valid OCP pull-secret JSON"
  fi
else
  fail "OCP pull secret missing: $PULL_SECRET_PATH (download from console.redhat.com/openshift/install/pull-secret)"
fi

if [[ -f "$SSH_PUBKEY_PATH" ]]; then
  if grep -qE '^(ssh-(rsa|ed25519|ecdsa)|ecdsa-sha2)' "$SSH_PUBKEY_PATH"; then
    pass "SSH pubkey at $SSH_PUBKEY_PATH"
  else
    fail "SSH pubkey at $SSH_PUBKEY_PATH doesn't look like an OpenSSH public key"
  fi
else
  fail "SSH pubkey missing: $SSH_PUBKEY_PATH (ssh-keygen -t ed25519)"
fi

# ---------- Section 3: AWS auth + identity ---------------------------

section "AWS authentication"

if ! command -v aws >/dev/null; then
  fail "Cannot proceed with AWS checks — aws CLI missing"
else
  aws_id=$(aws --profile "$AWS_PROFILE" sts get-caller-identity --output json 2>&1)
  if [[ "$aws_id" == *"\"Account\""* ]]; then
    acct=$(echo "$aws_id" | jq -r .Account)
    arn=$(echo "$aws_id" | jq -r .Arn)
    pass "AWS profile '$AWS_PROFILE' → account $acct"
    pass "   principal $arn"
  else
    fail "AWS profile '$AWS_PROFILE' not authenticated: $(echo "$aws_id" | head -1)"
    fail "   Run: aws sso login --profile $AWS_PROFILE"
  fi

  # Region validity
  if aws --profile "$AWS_PROFILE" ec2 describe-regions --region "$AWS_REGION" \
       --query 'Regions[?RegionName==`'"$AWS_REGION"'`].RegionName' --output text 2>/dev/null | grep -q "$AWS_REGION"; then
    pass "Region $AWS_REGION enabled in this account"
  else
    fail "Region $AWS_REGION not enabled / not reachable for this account"
  fi
fi

# ---------- Section 4: AWS quota headroom ----------------------------

section "AWS quota headroom"

if command -v aws >/dev/null && [[ "$aws_id" == *"\"Account\""* ]]; then
  # Standard m6i: vCPU "L-1216C542"
  vcpu_m=$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    service-quotas get-service-quota --service-code ec2 --quota-code L-1216C542 \
    --query 'Quota.Value' --output text 2>/dev/null)
  if [[ -n "$vcpu_m" && "$vcpu_m" != "None" ]]; then
    # 3× m6i.4xlarge = 48 vCPU; need ~64 with margin
    need_m=64
    if (( $(printf '%.0f' "$vcpu_m") >= need_m )); then
      pass "Standard (m6i) vCPU quota = $vcpu_m (need ~$need_m)"
    else
      fail "Standard vCPU quota = $vcpu_m (need ~$need_m). Run ./scripts/aws-quota-bootstrap.sh request"
    fi
  else
    warn "Could not read m6i vCPU quota (service-quotas API permission?)"
  fi

  # G family for GPUs: L-DB2E81BA  (only if ENABLE_GPU=true)
  if [[ "$ENABLE_GPU" == "true" ]]; then
    vcpu_g=$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA \
      --query 'Quota.Value' --output text 2>/dev/null)
    if [[ -n "$vcpu_g" && "$vcpu_g" != "None" ]]; then
      need_g=48
      if (( $(printf '%.0f' "$vcpu_g") >= need_g )); then
        pass "G-family vCPU quota = $vcpu_g (need ~$need_g for 1× g6e.12xlarge)"
      else
        fail "G-family vCPU quota = $vcpu_g (need ~$need_g for g6e.12xlarge)"
      fi
    fi
  else
    pass "GPUs disabled — skipping G-family vCPU quota check"
  fi

  # EIPs (NAT GW): L-0263D0A3 — 5 expected
  eip=$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 \
    --query 'Quota.Value' --output text 2>/dev/null)
  if [[ -n "$eip" && "$eip" != "None" ]]; then
    if (( $(printf '%.0f' "$eip") >= 5 )); then
      pass "Elastic IP quota = $eip (need 5)"
    else
      fail "Elastic IP quota = $eip (need 5 for NAT GWs across AZs)"
    fi
  fi
fi

# ---------- Section 5: DNS / Route 53 -------------------------------

section "DNS / Route 53"

if [[ -z "$BASE_DOMAIN" ]]; then
  warn "BASE_DOMAIN not set — skipping DNS checks. Set in terraform.tfvars or env."
else
  if command -v aws >/dev/null && [[ "$aws_id" == *"\"Account\""* ]]; then
    parent_zone=$(echo "$BASE_DOMAIN" | awk -F. '{ if (NF>=2) print $(NF-1)"."$NF; else print $0 }')
    zone_id=$(aws --profile "$AWS_PROFILE" route53 list-hosted-zones-by-name \
      --dns-name "$BASE_DOMAIN" --max-items 1 --query 'HostedZones[?Name==`'"$BASE_DOMAIN"'.`].Id' --output text 2>/dev/null)
    if [[ -n "$zone_id" && "$zone_id" != "None" ]]; then
      pass "Route 53 hosted zone exists for $BASE_DOMAIN ($zone_id)"
    else
      # Maybe parent zone exists and we'll delegate at apply
      parent_id=$(aws --profile "$AWS_PROFILE" route53 list-hosted-zones-by-name \
        --dns-name "$parent_zone" --max-items 1 --query 'HostedZones[?Name==`'"$parent_zone"'.`].Id' --output text 2>/dev/null)
      if [[ -n "$parent_id" && "$parent_id" != "None" ]]; then
        warn "No zone for $BASE_DOMAIN yet; parent zone $parent_zone present ($parent_id). Terraform will create the child zone + delegation."
      else
        fail "No hosted zone for $BASE_DOMAIN or $parent_zone in account. Create one (or NS-delegate) before apply."
      fi
    fi

    # Public resolution test
    if command -v dig >/dev/null; then
      ns=$(dig +short NS "$BASE_DOMAIN" 2>/dev/null | head -1)
      if [[ -n "$ns" ]]; then
        pass "Public NS resolution OK for $BASE_DOMAIN ($ns)"
      else
        warn "No public NS records for $BASE_DOMAIN yet (OK if you'll delegate after TF creates the child zone)"
      fi
    fi
  fi
fi

# ---------- Section 6: GitHub OAuth scaffolding ----------------------

section "GitHub OAuth (manual prerequisites)"

if [[ -z "$GITHUB_ORG" ]]; then
  warn "GITHUB_ORG not set — skipping GH-side checks. Set if you want to verify OAuth app placement."
elif [[ -z "${GITHUB_TOKEN:-}" ]]; then
  warn "GITHUB_TOKEN not set — can't verify org access. Manual: confirm you own/admin org $GITHUB_ORG"
else
  org_resp=$(curl -sf -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/orgs/$GITHUB_ORG" 2>&1 || true)
  if [[ "$org_resp" == *'"login"'* ]]; then
    pass "GitHub org '$GITHUB_ORG' reachable"
    # Confirm admin role
    role=$(curl -sf -H "Authorization: token $GITHUB_TOKEN" \
      "https://api.github.com/user/memberships/orgs/$GITHUB_ORG" 2>/dev/null \
      | jq -r .role 2>/dev/null)
    if [[ "$role" == "admin" ]]; then
      pass "Token has admin role on $GITHUB_ORG"
    else
      warn "Token's role on $GITHUB_ORG = $role (need admin to create OAuth apps + invite users)"
    fi
  else
    fail "Cannot reach GitHub org '$GITHUB_ORG' with provided token"
  fi
fi

echo
warn "Reminder: 3 GitHub OAuth apps must exist before bootstrap-sealed-secrets.sh runs."
warn "  Coder:    https://coder.apps.${CLUSTER_NAME}.${BASE_DOMAIN:-<base>}/api/v2/users/oauth2/github/callback"
warn "  OCP:      https://oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN:-<base>}/oauth2callback/github"
warn "  Grafana:  https://graf-coder.apps.${CLUSTER_NAME}.${BASE_DOMAIN:-<base>}/login/github"
warn "  (These are documented in docs/FRESH-ACCOUNT-BOOTSTRAP.md Step 5.)"

# ---------- Section 7: Bedrock model subscriptions -------------------

section "AWS Bedrock model subscriptions"

if command -v aws >/dev/null && [[ "$aws_id" == *"\"Account\""* ]]; then
  # We expect Sonnet 4 + Haiku 4 available in $AWS_REGION; Bedrock uses on-demand or provisioned profiles
  bedrock_models=$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    bedrock list-foundation-models \
    --query 'modelSummaries[?contains(modelId,`claude`)].modelId' --output text 2>/dev/null)
  if [[ -n "$bedrock_models" ]]; then
    pass "Bedrock reachable in $AWS_REGION ($(echo "$bedrock_models" | wc -w) Claude models listed)"
    if echo "$bedrock_models" | grep -q "claude-sonnet-4"; then
      pass "  claude-sonnet-4 present"
    else
      warn "  No claude-sonnet-4 model — subscribe in Bedrock console (Marketplace > Model access)"
    fi
  else
    fail "Bedrock not reachable / no models in $AWS_REGION (bedrock permissions? region support?)"
  fi
fi

# ---------- Summary --------------------------------------------------

section "Summary"
echo "  pass: $PASS_COUNT"
echo "  warn: $WARN_COUNT"
echo "  fail: $FAIL_COUNT"
echo

if (( FAIL_COUNT > 0 )); then
  echo -e "${R}Pre-flight FAILED.${N} Resolve the items above before running 'terraform apply'."
  exit 1
fi
if (( WARN_COUNT > 0 )); then
  echo -e "${Y}Pre-flight passed with warnings.${N} Review the warnings — some are blockers later in the flow."
  exit 0
fi
echo -e "${G}Pre-flight clean.${N} Proceed with: cd terraform && terraform apply"
exit 0
