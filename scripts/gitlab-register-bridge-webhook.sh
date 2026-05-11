#!/usr/bin/env bash
# Register the bridge service as a GitLab webhook on one or more
# projects (or instance-wide system hook).
#
# Workflow:
#   1. Bridge service is deployed (manifests/bridge/) and the
#      bridge-webhook-secret SealedSecret is applied.
#   2. This script reads the shared secret token from a Kubernetes
#      Secret (live, decoded) — admin kube context required.
#   3. Mints a GitLab admin PAT via gitlab-rails runner over SSH.
#   4. For each project path provided in $GITLAB_DEMO_PROJECTS
#      (comma-separated, e.g. "demo/sample-app,demo/webhooks-test"),
#      idempotently registers an Issues-events webhook pointing at
#      https://bridge.apps.cluster.rhsummit.coderdemo.io/webhook
#      with token verification.
#
# Idempotent: if a webhook with this URL already exists on the
# project, it's updated in place (token rotated, events refreshed).
# Re-running after a `make reset` is safe.
#
# Usage:
#   ./scripts/gitlab-register-bridge-webhook.sh
#   GITLAB_DEMO_PROJECTS="demo/sample-app,demo/customer-bugs" \
#     ./scripts/gitlab-register-bridge-webhook.sh
#
# Requires: kubectl/oc with admin context, AWS creds (TF state read),
# SSH to the GitLab EC2 host.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

BRIDGE_URL="${BRIDGE_URL:-https://bridge.apps.cluster.rhsummit.coderdemo.io/webhook}"
PROJECTS="${GITLAB_DEMO_PROJECTS:-demo/sample-app}"

# ── 1. Pull the bridge shared secret from the live cluster ──────────
echo "==> Reading bridge-webhook-secret/token from cluster..."
SECRET=$(oc -n coder get secret bridge-webhook-secret -o jsonpath='{.data.token}' | base64 -d)
if [ -z "${SECRET}" ]; then
  echo "ERROR: bridge-webhook-secret/token is empty in the coder namespace. Argo synced?" >&2
  exit 1
fi
echo "    OK (token length: ${#SECRET})"

# ── 2. Mint an admin PAT on the GitLab host ─────────────────────────
GITLAB_IP=$(cd "${TF_DIR}" && env -u AWS_ENDPOINT_URL AWS_PROFILE=ocp-deploy-acct \
  terraform output -raw gitlab_public_ip 2>/dev/null || echo "")
if [ -z "${GITLAB_IP}" ]; then
  echo "ERROR: terraform output gitlab_public_ip is empty." >&2; exit 1
fi

echo "==> Minting 7-day admin PAT on GitLab host ${GITLAB_IP}..."
PAT=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null \
  ec2-user@"${GITLAB_IP}" 'sudo gitlab-rails runner "
    u = User.find_by(username: %q(root))
    t = u.personal_access_tokens.create!(scopes: [:api, :admin_mode], name: %q(bridge-register), expires_at: 7.days.from_now)
    puts t.token
  "' 2>/dev/null | tail -1)
if [ -z "${PAT}" ] || [ "${PAT:0:6}" != "glpat-" ]; then
  echo "ERROR: failed to mint PAT. Got: ${PAT}" >&2; exit 1
fi
echo "    OK"

GITLAB_API="https://gitlab.rhsummit.coderdemo.io/api/v4"

# ── 3. Register/refresh webhook on each project ─────────────────────
IFS=',' read -ra PROJECT_ARR <<< "${PROJECTS}"
for project_path in "${PROJECT_ARR[@]}"; do
  project_path=$(echo "${project_path}" | xargs)  # trim
  [ -z "${project_path}" ] && continue

  enc=$(printf '%s' "${project_path}" | jq -sRr @uri)
  echo ""
  echo "==> Project: ${project_path}"

  # Get project ID (handles 404 gracefully)
  pid=$(curl -sf -H "PRIVATE-TOKEN: ${PAT}" \
    "${GITLAB_API}/projects/${enc}" 2>/dev/null | jq -r '.id // empty')
  if [ -z "${pid}" ]; then
    echo "    SKIP — project not found (create it manually or via TF first)"
    continue
  fi
  echo "    Project ID: ${pid}"

  # Existing webhook with same URL?
  existing_id=$(curl -sf -H "PRIVATE-TOKEN: ${PAT}" \
    "${GITLAB_API}/projects/${pid}/hooks" \
    | jq -r ".[] | select(.url == \"${BRIDGE_URL}\") | .id" | head -1 || echo "")

  COMMON_ARGS=(
    --data-urlencode "url=${BRIDGE_URL}"
    --data-urlencode "token=${SECRET}"
    --data-urlencode "issues_events=true"
    --data-urlencode "push_events=false"
    --data-urlencode "merge_requests_events=false"
    --data-urlencode "tag_push_events=false"
    --data-urlencode "note_events=false"
    --data-urlencode "enable_ssl_verification=true"
  )

  if [ -n "${existing_id}" ]; then
    echo "    Updating existing hook ${existing_id}..."
    curl -sf -X PUT -H "PRIVATE-TOKEN: ${PAT}" \
      "${GITLAB_API}/projects/${pid}/hooks/${existing_id}" \
      "${COMMON_ARGS[@]}" >/dev/null
    echo "    OK (updated)"
  else
    echo "    Creating new hook..."
    curl -sf -X POST -H "PRIVATE-TOKEN: ${PAT}" \
      "${GITLAB_API}/projects/${pid}/hooks" \
      "${COMMON_ARGS[@]}" >/dev/null
    echo "    OK (created)"
  fi
done

echo ""
echo "Done. Test with: open an issue and add a label like \`template:demo-ai-gov-firewall-ocp\`."
