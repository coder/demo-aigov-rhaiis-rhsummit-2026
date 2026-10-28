#!/usr/bin/env bash
# Mirror the workspace base images from GHCR into the OpenShift internal
# registry, so the -ocp templates pull from an in-cluster, self-contained
# source instead of reaching out to an external registry at workspace-create
# time. This is the "secure the environment from external software
# supply-chain attacks" posture for the demo: the cluster never pulls
# workspace images from the public internet.
#
# Source of truth for the images is still GHCR (built by
# .github/workflows/build-images.yml). This script copies the blobs into the
# internal registry; re-run it whenever the GHCR images are rebuilt.
#
# Prereqs:
#   - logged into the cluster with `oc` as a user that can create
#     imagestreams in $NS and push to the internal registry
#   - internal registry default route exposed:
#       oc patch configs.imageregistry.operator.openshift.io/cluster \
#         --type=merge -p '{"spec":{"defaultRoute":true}}'
set -euo pipefail

SRC="${SRC:-ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026}"
NS="${NS:-coder-workspaces}"
IMAGES=(ubi9-base-workspace ubi9-node-workspace agents-config-tools)

HOST="$(oc get route -n openshift-image-registry default-route -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [ -z "$HOST" ]; then
  echo "ERROR: internal registry default route not found. Enable it with:" >&2
  echo "  oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{\"spec\":{\"defaultRoute\":true}}'" >&2
  exit 1
fi

# Mint a short-lived push token via a dedicated SA. Works even when the
# current login is cert-based cluster-admin (which has no bearer token).
oc create sa img-mirror -n "$NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc policy add-role-to-user system:image-builder -z img-mirror -n "$NS" >/dev/null
TOKEN="$(oc create token img-mirror -n "$NS" --duration=2h)"

AUTH_FILE="$(mktemp)"
trap 'rm -f "$AUTH_FILE"' EXIT
printf '{"auths":{"%s":{"auth":"%s"}}}' \
  "$HOST" "$(printf 'unused:%s' "$TOKEN" | base64 -w0)" > "$AUTH_FILE"

MAPPINGS=()
for img in "${IMAGES[@]}"; do
  MAPPINGS+=("$SRC/$img:latest=$HOST/$NS/$img:latest")
done

echo "Mirroring ${#IMAGES[@]} images: $SRC -> $HOST/$NS"
oc image mirror --registry-config="$AUTH_FILE" \
  --keep-manifest-list --filter-by-os=linux/amd64 "${MAPPINGS[@]}"

echo
echo "Done. In-cluster pull path (used by the templates' image_registry default):"
echo "  image-registry.openshift-image-registry.svc:5000/$NS/<image>:latest"
