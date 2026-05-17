#!/usr/bin/env bash
set -euo pipefail

# scripts/configure-manifests.sh
#
# Reads cluster-specific values from Terraform outputs (or from env if TF
# isn't installed locally) and patches all manifests + gitops application
# values + scripts + service config that hardcode the demo cluster's
# hostnames, account ID, region, or infraName. Run this after
# `terraform apply` completes, or any time the underlying values change.
#
# The script is idempotent — safe to run multiple times. It uses sed
# replacements anchored on the OLD canonical strings, so re-running on
# already-patched files is a no-op.
#
# Usage:
#   ./scripts/configure-manifests.sh [--terraform-dir ./terraform]
#
# Or skip Terraform entirely (e.g. for testing):
#   CLUSTER_FQDN=cluster.example.com \
#   CLUSTER_ZONE_ID=ZXXXXX \
#   AWS_ACCOUNT_ID=123456789012 \
#   AWS_REGION=us-east-1 \
#   CLUSTER_INFRA_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}') \
#   IMAGE_REGISTRY=ghcr.io/yourorg/yourfork \
#     ./scripts/configure-manifests.sh --skip-terraform
#
# After running:
#   1. git diff to review
#   2. git commit + push (Argo CD will pick up next sync)
#   3. oc apply -f gitops/bootstrap/root-app.yaml  (first-time only)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TF_DIR=""
SKIP_TF=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --terraform-dir) TF_DIR="$2"; shift 2 ;;
    --skip-terraform) SKIP_TF=1; shift ;;
    --help|-h)
      grep '^# ' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) shift ;;
  esac
done
TF_DIR="${TF_DIR:-$REPO_ROOT/terraform}"

# --- Source values: Terraform outputs or env ---

if [[ $SKIP_TF -eq 0 ]]; then
  if ! command -v terraform >/dev/null; then
    echo "ERROR: terraform CLI not on PATH. Use --skip-terraform with env vars instead." >&2
    exit 1
  fi
  echo "==> Reading Terraform outputs from $TF_DIR..."
  pushd "$TF_DIR" >/dev/null
  CLUSTER_FQDN="${CLUSTER_FQDN:-$(terraform output -raw cluster_fqdn 2>/dev/null || true)}"
  CLUSTER_ZONE_ID="${CLUSTER_ZONE_ID:-$(terraform output -raw cluster_zone_id 2>/dev/null || true)}"
  AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(terraform output -raw aws_account_id 2>/dev/null || true)}"
  AWS_REGION="${AWS_REGION:-$(terraform output -raw aws_region 2>/dev/null || true)}"
  popd >/dev/null
fi

# Fallbacks via AWS CLI / oc / env
: "${AWS_ACCOUNT_ID:=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '')}"
: "${AWS_REGION:=us-east-1}"
: "${CLUSTER_INFRA_NAME:=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo '')}"
: "${IMAGE_REGISTRY:=ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026}"
: "${GITHUB_ORG:=demo-rhsummit-users}"

# Validate
for v in CLUSTER_FQDN AWS_ACCOUNT_ID AWS_REGION; do
  if [[ -z "${!v}" ]]; then
    echo "ERROR: $v is empty. Set it in env or ensure Terraform outputs are available." >&2
    exit 1
  fi
done

# Derived
APPS_DOMAIN="apps.${CLUSTER_FQDN}"
API_DOMAIN="api.${CLUSTER_FQDN}"
CODER_DOMAIN="coder.${APPS_DOMAIN}"
GRAFANA_DOMAIN="graf-coder.${APPS_DOMAIN}"
KEYCLOAK_DOMAIN="keycloak.${APPS_DOMAIN}"
# GitLab host follows the base_domain (NOT under apps.) per terraform/gitlab/
GITLAB_DOMAIN="gitlab.${CLUSTER_FQDN#cluster.}"
[[ "$CLUSTER_FQDN" == cluster.* ]] || GITLAB_DOMAIN="gitlab.${CLUSTER_FQDN}"

# IRSA role ARN (used by Coder server's SA + cert-manager's SA)
CLUSTER_NAME_TF="${CLUSTER_FQDN%%.*}"   # e.g. "cluster" from "cluster.rhsummit.coderdemo.io"
CODER_BEDROCK_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/demo/${CLUSTER_NAME_TF}-coder-bedrock"
CERT_MANAGER_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/demo/${CLUSTER_NAME_TF}-cert-manager-route53"

cat <<EOF
==> Resolved values:
    CLUSTER_FQDN:              $CLUSTER_FQDN
    CLUSTER_ZONE_ID:           ${CLUSTER_ZONE_ID:-<unset>}
    AWS_ACCOUNT_ID:            $AWS_ACCOUNT_ID
    AWS_REGION:                $AWS_REGION
    CLUSTER_INFRA_NAME:        ${CLUSTER_INFRA_NAME:-<unset; MachineSet patching skipped>}
    IMAGE_REGISTRY:            $IMAGE_REGISTRY
    GITHUB_ORG:                $GITHUB_ORG

==> Derived:
    APPS_DOMAIN:               $APPS_DOMAIN
    API_DOMAIN:                $API_DOMAIN
    CODER_DOMAIN:              $CODER_DOMAIN
    GRAFANA_DOMAIN:            $GRAFANA_DOMAIN
    KEYCLOAK_DOMAIN:           $KEYCLOAK_DOMAIN
    GITLAB_DOMAIN:             $GITLAB_DOMAIN
    CODER_BEDROCK_ROLE_ARN:    $CODER_BEDROCK_ROLE_ARN
    CERT_MANAGER_ROLE_ARN:     $CERT_MANAGER_ROLE_ARN

EOF

cd "$REPO_ROOT"

# --- Source values: identity (OLD canonical strings from the demo booth) ---

# These are the values we're replacing FROM. Anchored on the rhsummit
# booth so re-running this on a freshly cloned repo always works.
OLD_CLUSTER_FQDN="cluster.rhsummit.coderdemo.io"
OLD_APPS_DOMAIN="apps.cluster.rhsummit.coderdemo.io"
OLD_API_DOMAIN="api.cluster.rhsummit.coderdemo.io"
OLD_CODER_DOMAIN="coder.apps.cluster.rhsummit.coderdemo.io"
OLD_GRAFANA_DOMAIN="graf-coder.apps.cluster.rhsummit.coderdemo.io"
OLD_KEYCLOAK_DOMAIN="keycloak.apps.cluster.rhsummit.coderdemo.io"
OLD_GITLAB_DOMAIN="gitlab.rhsummit.coderdemo.io"
OLD_AWS_ACCOUNT_ID="342934376218"
OLD_CLUSTER_INFRA_NAME="cluster-pqc4z"
OLD_GITHUB_ORG="demo-rhsummit-users"
OLD_IMAGE_REGISTRY="ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026"

# Single sed pass per file — order matters: replace the most-specific
# hostnames FIRST so a generic later replacement doesn't double-apply.
patch_file() {
  local f="$1"
  [[ ! -f "$f" ]] && return
  sed -i \
    -e "s|${OLD_GRAFANA_DOMAIN}|${GRAFANA_DOMAIN}|g" \
    -e "s|${OLD_KEYCLOAK_DOMAIN}|${KEYCLOAK_DOMAIN}|g" \
    -e "s|${OLD_CODER_DOMAIN}|${CODER_DOMAIN}|g" \
    -e "s|${OLD_GITLAB_DOMAIN}|${GITLAB_DOMAIN}|g" \
    -e "s|${OLD_API_DOMAIN}|${API_DOMAIN}|g" \
    -e "s|${OLD_APPS_DOMAIN}|${APPS_DOMAIN}|g" \
    -e "s|${OLD_CLUSTER_FQDN}|${CLUSTER_FQDN}|g" \
    -e "s|gitlab\\\\.rhsummit\\\\.coderdemo\\\\.io|${GITLAB_DOMAIN//./\\\\.}|g" \
    -e "s|${OLD_AWS_ACCOUNT_ID}|${AWS_ACCOUNT_ID}|g" \
    -e "s|${OLD_GITHUB_ORG}|${GITHUB_ORG}|g" \
    -e "s|${OLD_IMAGE_REGISTRY}|${IMAGE_REGISTRY}|g" \
    "$f"
}

# --- Patch all known-hostname-bearing files ---

echo "==> Patching hostnames + account ID + GH org + image registry across the repo..."
FILES=(
  # cert-manager + routes
  manifests/cert-manager/cluster-issuer.yaml
  manifests/cert-manager/platform-certs.yaml
  manifests/coder/certificate.yaml
  manifests/coder/route.yaml
  manifests/observability/certificate.yaml
  manifests/observability/route.yaml
  # bridge
  manifests/bridge/deployment.yaml
  manifests/bridge/route.yaml
  # keycloak
  manifests/keycloak/keycloak.yaml
  manifests/keycloak/route.yaml
  manifests/keycloak/realm-demo.yaml
  # cluster-config (OAuth IdPs)
  manifests/cluster-config/oauth-cluster.yaml
  # coder-agents-config Job + rendered configmap
  manifests/coder-agents-config/job.yaml
  manifests/coder-agents-config/configmap.yaml
  # gitops Application values blocks
  gitops/apps/coder/application.yaml
  gitops/apps/observability/application.yaml
  # scripts that hardcode hostnames as defaults.
  # NOTE: scripts/fix-bedrock-irsa.sh is intentionally EXCLUDED — it uses
  # a hyphen-encoded OIDC provider URL (cluster-rhsummit-coderdemo-io-oidc...)
  # that doesn't match the dotted FQDN form. That script is a one-shot
  # recovery tool, not a catalog-deploy step; if catalog deployers need
  # to re-bind the IRSA role they should derive the OIDC URL via
  #   oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}'
  scripts/gitlab-register-bridge-webhook.sh
  scripts/gitlab-create-coder-oauth-app.sh
  scripts/reset-demo.sh
  scripts/gitlab-bootstrap-personas.sh
  # bridge service code defaults
  services/bridge/internal/config/config.go
  services/bridge/internal/handler/handler.go
)
for f in "${FILES[@]}"; do
  if [[ -f "$f" ]]; then
    patch_file "$f"
    echo "    patched: $f"
  fi
done

# --- Patch the IRSA role ARN (more specific — full ARN replacement) ---

echo "==> Patching IRSA role ARNs in gitops/apps/coder/application.yaml..."
sed -i \
  -e "s|arn:aws:iam::${OLD_AWS_ACCOUNT_ID}:role/demo/cluster-coder-bedrock|${CODER_BEDROCK_ROLE_ARN}|g" \
  -e "s|arn:aws:iam::${OLD_AWS_ACCOUNT_ID}:role/demo/cluster-cert-manager-route53|${CERT_MANAGER_ROLE_ARN}|g" \
  gitops/apps/coder/application.yaml

# --- Patch certificate zone ID for cert-manager ---

if [[ -n "${CLUSTER_ZONE_ID:-}" ]]; then
  echo "==> Patching Route 53 zone ID in cluster-issuer..."
  sed -i "s|hostedZoneID: .*|hostedZoneID: ${CLUSTER_ZONE_ID}|g" \
    manifests/cert-manager/cluster-issuer.yaml
fi

# --- Patch MachineSet infraName labels (post-OCP-install) ---

if [[ -n "${CLUSTER_INFRA_NAME}" ]]; then
  echo "==> Patching MachineSet infraName from '${OLD_CLUSTER_INFRA_NAME}' to '${CLUSTER_INFRA_NAME}'..."
  for f in manifests/machinesets/*.yaml manifests/rhaiis/vllm-deployment.yaml; do
    [[ -f "$f" ]] || continue
    sed -i "s|${OLD_CLUSTER_INFRA_NAME}|${CLUSTER_INFRA_NAME}|g" "$f"
    echo "    patched: $f"
  done
else
  echo "==> SKIP MachineSet infraName patch — \$CLUSTER_INFRA_NAME is unset."
  echo "    Run after the cluster is installed:"
  echo "    CLUSTER_INFRA_NAME=\$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}') $0 ..."
fi

# --- Patch AWS region in MachineSets + Bedrock URLs ---

# Region defaults to us-east-1 in many places; substitute carefully.
echo "==> Patching AWS region references..."
for f in manifests/machinesets/*.yaml manifests/rhaiis/vllm-deployment.yaml manifests/coder-agents-config/job.yaml manifests/coder-agents-config/configmap.yaml gitops/apps/coder/application.yaml gitops/apps/coder-provisioner/application.yaml scripts/aws-quota-bootstrap.sh; do
  [[ -f "$f" ]] || continue
  sed -i \
    -e "s|us-east-1a|${AWS_REGION}a|g" \
    -e "s|us-east-1b|${AWS_REGION}b|g" \
    -e "s|us-east-1c|${AWS_REGION}c|g" \
    -e "s|us-east-1d|${AWS_REGION}d|g" \
    -e "s|us-east-1|${AWS_REGION}|g" \
    "$f"
done

# --- Summary ---

cat <<EOF

==> Done. Manifests configured for:
    Cluster: ${CLUSTER_FQDN}
    AWS account: ${AWS_ACCOUNT_ID} in ${AWS_REGION}
    Image registry: ${IMAGE_REGISTRY}

==> Next steps:
    1. git diff   # review the substitutions
    2. git add -A && git commit -m 'chore: configure manifests for <your-deployment>'
    3. git push   # Argo CD picks up the change automatically
    4. First-time only:  oc apply -f gitops/bootstrap/root-app.yaml

==> Then continue with:
    scripts/bootstrap-sealed-secrets.sh   # mint + seal the 14 per-deploy secrets
    scripts/gitlab-bootstrap-personas.sh  # pre-create demo personas in GitLab
EOF
