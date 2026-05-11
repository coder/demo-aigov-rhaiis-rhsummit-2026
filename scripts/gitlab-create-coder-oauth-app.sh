#!/usr/bin/env bash
# Create the "Coder workspace external auth" OAuth application inside
# the running GitLab instance, then emit a SealedSecret manifest with
# the resulting client_id + client_secret.
#
# Intended workflow:
#   1. terraform apply for module.gitlab finishes (GitLab + registry live)
#   2. Run this script — it logs in as root via the password in the
#      Terraform output, creates the OAuth app, and seals the creds.
#   3. Commit the generated SealedSecret + the env-var swap in
#      gitops/apps/coder/application.yaml (CODER_EXTERNAL_AUTH_0_* now
#      points at gitlab rather than github).
#   4. Argo CD picks up the change; workspace `git push` flows through
#      the booth GitLab instead of personal GitHub.
#
# Why this isn't a Job in the cluster: GitLab's bootstrap doesn't run
# until after `terraform apply`, which itself is outside the Argo flow.
# Bootstrapping an OAuth app declaratively would need either the GitLab
# Terraform provider (extra plumbing for a one-time setup) or a Job
# that polls for GitLab availability (premature). Scripted is fine for
# the booth.
#
# Usage:
#   ./scripts/gitlab-create-coder-oauth-app.sh [coder_redirect_uri]
#
# Defaults:
#   GitLab URL  : https://gitlab.rhsummit.coderdemo.io (from TF output)
#   Coder redir : https://coder.apps.cluster.rhsummit.coderdemo.io/external-auth/gitlab/callback
#   App name    : coder-workspace-external-auth
#   Scopes      : read_user read_repository write_repository api
#
# Requires: curl, jq, kubeseal (installed in this workspace), terraform.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

GITLAB_URL=$(cd "${TF_DIR}" && env -u AWS_ENDPOINT_URL AWS_PROFILE=ocp-deploy-acct terraform output -raw gitlab_url 2>/dev/null || echo "")
if [ -z "${GITLAB_URL}" ]; then
  GITLAB_URL="https://gitlab.rhsummit.coderdemo.io"
fi

REDIRECT_URI="${1:-https://coder.apps.cluster.rhsummit.coderdemo.io/external-auth/gitlab/callback}"
APP_NAME="coder-workspace-external-auth"
# Scopes must be a SUPERSET of what CODER_EXTERNAL_AUTH_0_SCOPES
# requests — GitLab rejects /oauth/authorize with "invalid scope" if
# any requested scope isn't in this list. See docs/decisions.md §32.
#  - api              : full API, covers /oauth/token/info validate
#  - write_repository : git push to GitLab repos
#  - read_registry    : pull from registry.gitlab.<base_domain>
#  - write_registry   : push to registry.gitlab.<base_domain>
SCOPES="api write_repository read_registry write_registry"

# ── Get root password from Terraform sensitive output ──────────────
GITLAB_ROOT_PASSWORD=$(cd "${TF_DIR}" && env -u AWS_ENDPOINT_URL AWS_PROFILE=ocp-deploy-acct terraform output -raw gitlab_root_password 2>/dev/null)
if [ -z "${GITLAB_ROOT_PASSWORD}" ]; then
  echo "ERROR: terraform output gitlab_root_password is empty. Has the GitLab module been applied?" >&2
  exit 1
fi

# ── Wait for GitLab to be ready ────────────────────────────────────
echo "==> Probing ${GITLAB_URL}/users/sign_in for HTTP 200..."
for i in $(seq 1 30); do
  http=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "${GITLAB_URL}/users/sign_in" || echo "000")
  if [ "${http}" = "200" ]; then
    echo "    OK"
    break
  fi
  echo "    HTTP ${http} (try ${i}/30) — sleeping 10s"
  sleep 10
done

# ── Mint a short-lived admin PAT via gitlab-rails on the host ──────
# GitLab 18 removed the resource-owner password grant, so we can't
# `POST /oauth/token` as root anymore. Instead, ssh to the GitLab EC2
# host and use `gitlab-rails runner` to mint a 1-day admin PAT, then
# use it for the applications API. Requires SSH access to the host
# (the same SSH key the cluster was bootstrapped with — see
# `aws_key_pair.rhsummit-gitlab`).
GITLAB_HOST_IP=$(cd "${TF_DIR}" && env -u AWS_ENDPOINT_URL AWS_PROFILE=ocp-deploy-acct \
  terraform output -raw gitlab_public_ip 2>/dev/null)
if [ -z "${GITLAB_HOST_IP}" ]; then
  echo "ERROR: terraform output gitlab_public_ip is empty." >&2; exit 1
fi
echo "==> Minting 1-day admin PAT on GitLab host ${GITLAB_HOST_IP}..."
ROOT_TOKEN=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null \
  ec2-user@"${GITLAB_HOST_IP}" 'sudo gitlab-rails runner "
    u = User.find_by(username: %q(root))
    t = u.personal_access_tokens.create!(scopes: [:api, :admin_mode], name: %q(coder-oauth-bootstrap), expires_at: 1.day.from_now)
    puts t.token
  "' 2>/dev/null | tail -1)
if [ -z "${ROOT_TOKEN}" ] || [ "${ROOT_TOKEN:0:6}" != "glpat-" ]; then
  echo "ERROR: failed to mint admin PAT. Got: ${ROOT_TOKEN}" >&2; exit 1
fi
echo "    OK"

# GitLab's PRIVATE-TOKEN header accepts a PAT directly; no Bearer
# wrapping needed.
AUTH_HEADER="PRIVATE-TOKEN: ${ROOT_TOKEN}"

# ── Idempotent: delete existing app of the same name if present ────
echo "==> Removing any prior \"${APP_NAME}\" OAuth application..."
EXISTING_ID=$(curl -sf -H "${AUTH_HEADER}" \
  "${GITLAB_URL}/api/v4/applications" \
  | jq -r ".[] | select(.application_name==\"${APP_NAME}\") | .id" | head -1 || echo "")
if [ -n "${EXISTING_ID}" ]; then
  curl -sf -X DELETE -H "${AUTH_HEADER}" \
    "${GITLAB_URL}/api/v4/applications/${EXISTING_ID}" >/dev/null
  echo "    Deleted id=${EXISTING_ID}"
fi

# ── Create the new instance-wide OAuth application ────────────────
echo "==> Creating OAuth application \"${APP_NAME}\"..."
CREATE_RESP=$(curl -sf -X POST -H "${AUTH_HEADER}" \
  "${GITLAB_URL}/api/v4/applications" \
  --data-urlencode "name=${APP_NAME}" \
  --data-urlencode "redirect_uri=${REDIRECT_URI}" \
  --data-urlencode "scopes=${SCOPES}" \
  --data-urlencode "confidential=true" \
  --data-urlencode "trusted=true")

CLIENT_ID=$(echo "${CREATE_RESP}" | jq -r '.application_id')
CLIENT_SECRET=$(echo "${CREATE_RESP}" | jq -r '.secret')

if [ -z "${CLIENT_ID}" ] || [ "${CLIENT_ID}" = "null" ]; then
  echo "ERROR: app creation failed. Response: ${CREATE_RESP}" >&2
  exit 1
fi

echo "    application_id=${CLIENT_ID}"
echo "    secret=${CLIENT_SECRET:0:8}... (suppressed; full value goes into sealed secret)"

# ── Seal as a SealedSecret in the `coder` namespace ───────────────
SEALED_OUT="${REPO_ROOT}/manifests/secrets/gitlab-coder-external-auth.yaml"
echo "==> Sealing into ${SEALED_OUT}..."

kubectl -n coder create secret generic gitlab-coder-external-auth \
  --from-literal=client-id="${CLIENT_ID}" \
  --from-literal=client-secret="${CLIENT_SECRET}" \
  --dry-run=client -o yaml \
  | kubeseal \
      --controller-name=sealed-secrets \
      --controller-namespace=sealed-secrets \
      --format=yaml \
  > "${SEALED_OUT}"

echo "    OK"
echo ""
echo "Next steps:"
echo "  1. git add manifests/secrets/gitlab-coder-external-auth.yaml"
echo "  2. Update gitops/apps/coder/application.yaml so CODER_EXTERNAL_AUTH_0_*"
echo "     points at the gitlab provider (see template at end of this script)."
echo "  3. git commit + push; Argo CD applies + rolls Coder."
