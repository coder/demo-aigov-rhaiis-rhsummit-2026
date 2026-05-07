#!/usr/bin/env bash
# scripts/stamp-fqdn.sh — Replace FQDN placeholders in manifests with the
# value from .env. Run after changing CLUSTER_NAME or BASE_DOMAIN.
#
# Usage:
#   source .env && ./scripts/stamp-fqdn.sh
#
# Idempotent — safe to re-run.

set -euo pipefail

: "${CLUSTER_FQDN:?ERROR: CLUSTER_FQDN not set. Run: source .env}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPS_FQDN="apps.${CLUSTER_FQDN}"

echo "Stamping FQDN: ${CLUSTER_FQDN} (apps: ${APPS_FQDN})"

# Pattern: any *.apps.<something>.coderdemo.io or apps.<something>.coderdemo.io
# We replace the apps domain portion in all relevant files.
find "$REPO_ROOT" \( -path '*/.git' -prune \) -o \
  \( -name '*.yaml' -o -name '*.yml' \) -print0 |
  xargs -0 sed -i '' \
    -e "s|apps\.[a-z0-9.-]*\.coderdemo\.io|${APPS_FQDN}|g"

echo "Done. Verify with: grep -r '${APPS_FQDN}' manifests/ gitops/ coder-templates/"
