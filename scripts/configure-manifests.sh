#!/usr/bin/env bash
set -euo pipefail

# scripts/configure-manifests.sh
#
# Reads cluster-specific values from terraform outputs and patches all
# manifests/gitops files that contain placeholder tokens. Run this after
# `terraform apply` completes (or any time you change cluster_name /
# base_domain in tfvars).
#
# Usage:
#   ./scripts/configure-manifests.sh [--terraform-dir ./terraform]
#
# The script is idempotent — safe to run multiple times.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="${1:---terraform-dir}"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --terraform-dir) TF_DIR="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--terraform-dir ./terraform]"
      echo ""
      echo "Reads terraform outputs and patches manifests with cluster-specific values."
      echo "Run after 'terraform apply' or when cluster_name/base_domain change."
      exit 0
      ;;
    *) shift ;;
  esac
done

TF_DIR="${TF_DIR:-$REPO_ROOT/terraform}"

echo "==> Reading terraform outputs from $TF_DIR..."
cd "$TF_DIR"

CLUSTER_FQDN=$(terraform output -raw cluster_fqdn 2>/dev/null)
CLUSTER_ZONE_ID=$(terraform output -raw cluster_zone_id 2>/dev/null)
APPS_DOMAIN="apps.${CLUSTER_FQDN}"
API_DOMAIN="api.${CLUSTER_FQDN}"
CODER_DOMAIN="coder.${APPS_DOMAIN}"
GRAFANA_DOMAIN="grafana.${APPS_DOMAIN}"

echo "    CLUSTER_FQDN:    $CLUSTER_FQDN"
echo "    CLUSTER_ZONE_ID: $CLUSTER_ZONE_ID"
echo "    APPS_DOMAIN:     $APPS_DOMAIN"
echo "    CODER_DOMAIN:    $CODER_DOMAIN"
echo "    GRAFANA_DOMAIN:  $GRAFANA_DOMAIN"
echo "    API_DOMAIN:      $API_DOMAIN"

cd "$REPO_ROOT"

# --- Patch manifests ---

echo "==> Patching manifests/cert-manager/cluster-issuer.yaml..."
sed -i "s|hostedZoneID: .*|hostedZoneID: ${CLUSTER_ZONE_ID}|g" \
  manifests/cert-manager/cluster-issuer.yaml

echo "==> Patching manifests/cert-manager/platform-certs.yaml..."
sed -i \
  -e "s|\"\\*\\.apps\\.[^\"]*\"|\"*.${APPS_DOMAIN}\"|g" \
  -e "s|api\\.[a-z0-9.-]*coderdemo\\.io|${API_DOMAIN}|g" \
  -e "s|apps\\.[a-z0-9.-]*coderdemo\\.io|${APPS_DOMAIN}|g" \
  manifests/cert-manager/platform-certs.yaml

echo "==> Patching manifests/coder/certificate.yaml..."
sed -i \
  -e "s|coder\\.apps\\.[a-z0-9.-]*coderdemo\\.io|${CODER_DOMAIN}|g" \
  -e "s|\"\\*\\.coder\\.apps\\.[^\"]*\"|\"*.${CODER_DOMAIN}\"|g" \
  manifests/coder/certificate.yaml

echo "==> Patching manifests/coder/route.yaml..."
sed -i \
  -e "s|coder\\.apps\\.[a-z0-9.-]*coderdemo\\.io|${CODER_DOMAIN}|g" \
  -e "s|x\\.coder\\.apps\\.[a-z0-9.-]*coderdemo\\.io|x.${CODER_DOMAIN}|g" \
  manifests/coder/route.yaml

echo "==> Patching manifests/observability/certificate.yaml..."
sed -i "s|grafana\\.apps\\.[a-z0-9.-]*coderdemo\\.io|${GRAFANA_DOMAIN}|g" \
  manifests/observability/certificate.yaml

echo "==> Patching manifests/observability/route.yaml..."
sed -i "s|grafana\\.apps\\.[a-z0-9.-]*coderdemo\\.io|${GRAFANA_DOMAIN}|g" \
  manifests/observability/route.yaml

echo "==> Patching gitops/apps/coder/application.yaml..."
sed -i \
  -e "s|coder\\.apps\\.[a-z0-9.-]*coderdemo\\.io|${CODER_DOMAIN}|g" \
  -e "s|\"\\*\\.coder\\.apps\\.[^\"]*\"|\"*.${CODER_DOMAIN}\"|g" \
  gitops/apps/coder/application.yaml

echo "==> Patching gitops/apps/observability/application.yaml..."
sed -i "s|grafana\\.apps\\.[a-z0-9.-]*coderdemo\\.io|${GRAFANA_DOMAIN}|g" \
  gitops/apps/observability/application.yaml

echo ""
echo "==> Done. Manifests configured for cluster: $CLUSTER_FQDN"
echo "    Commit the changes and push to trigger Argo CD sync."

# ── Apply root app ──────────────────────────────────────────────────────────
# The root app is intentionally NOT applied by terraform. It's applied here
# after manifests are configured so Argo CD never syncs stale/wrong values.

KUBECONFIG="${TF_DIR}/.cluster/auth/kubeconfig"
if [[ -f "$KUBECONFIG" ]]; then
  echo ""
  echo "==> Applying Argo CD root Application (app-of-apps)..."
  export KUBECONFIG
  oc apply -f "$REPO_ROOT/gitops/bootstrap/root-app.yaml"
  echo "==> Root app applied. Watch sync with:"
  echo "       oc get applications -n openshift-gitops -w"
else
  echo ""
  echo "    NOTE: kubeconfig not found at $KUBECONFIG"
  echo "    Apply the root app manually after committing:"
  echo "       oc apply -f gitops/bootstrap/root-app.yaml"
fi
