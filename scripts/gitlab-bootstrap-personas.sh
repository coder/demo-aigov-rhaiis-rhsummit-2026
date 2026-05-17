#!/usr/bin/env bash
# scripts/gitlab-bootstrap-personas.sh
#
# Pre-creates the demo personas (alice, bob, demoadm) in GitLab with
# their Keycloak OIDC identity already linked. Adds project-level
# membership so that first-day-of-demo flows work without manual
# clicking in the GitLab UI.
#
# Why this exists: GitLab CE has no native OIDC-group-to-role mapping.
# Without this script, a deployer would have to:
#   1. Wait for each persona to log in for the first time (auto-creates them)
#   2. Manually add bob to project-of-interest as Developer
#   3. Manually run gitlab-promote-demoadmins.sh for demoadm
#
# This script does all of that proactively, so the demo works the moment
# the cluster is up + GitLab is reachable.
#
# Requirements:
#   - GitLab admin PAT in env: GITLAB_ADMIN_PAT
#   - GitLab URL in env (default: derived from cluster_fqdn):
#       GITLAB_URL=https://gitlab.<cluster_fqdn>
#   - Existing GitLab instance (terraform/gitlab + initial admin done)
#
# Idempotent — safe to re-run. Existing users get their memberships
# refreshed; missing memberships are added; failures are non-fatal.
#
# Usage:
#   GITLAB_ADMIN_PAT=glpat-... GITLAB_URL=https://gitlab.rhsummit.coderdemo.io \
#     ./scripts/gitlab-bootstrap-personas.sh
#
# To customize personas / projects, override these env vars:
#   DEMO_PERSONAS=alice,bob,demoadm
#   DEMO_PROJECTS=alice/artemis-sim,demo/sample-app    # bob gets Developer on each
#   DEMO_EMAIL_DOMAIN=demo.rhsummit.coderdemo.io
#
# See docs/CATALOG-READINESS.md §G2 for context on why this exists.

set -euo pipefail

GITLAB_URL="${GITLAB_URL:?GITLAB_URL must be set (e.g. https://gitlab.rhsummit.coderdemo.io)}"
GITLAB_URL="${GITLAB_URL%/}"
: "${GITLAB_ADMIN_PAT:?GITLAB_ADMIN_PAT must be set (admin-level PAT)}"

DEMO_PERSONAS="${DEMO_PERSONAS:-alice,bob,demoadm}"
DEMO_PROJECTS="${DEMO_PROJECTS:-alice/artemis-sim,demo/sample-app}"
DEMO_EMAIL_DOMAIN="${DEMO_EMAIL_DOMAIN:-demo.rhsummit.coderdemo.io}"

# Per-persona attributes. Format: username:full_name:role
# role determines GitLab project access_level on $DEMO_PROJECTS:
#   developer = 30 (read + write + create issues/MRs)
#   reporter  = 20 (read + create issues + comment)
#   admin     = handled separately via gitlab-promote-demoadmins.sh
declare -A PERSONA_FULLNAME=(
  [alice]="Alice Anderson"
  [bob]="Bob Brown"
  [demoadm]="Demo Admin"
)
declare -A PERSONA_ROLE=(
  [alice]="developer"   # owner of alice/* namespace; Developer on demo/* is moot
  [bob]="developer"     # PM persona — Developer lets bob create+assign+label issues + comment
  [demoadm]="admin"     # instance admin via gitlab-promote-demoadmins.sh
)

# GitLab access_level integers (https://docs.gitlab.com/ee/api/access_requests.html)
declare -A LEVEL=(
  [guest]=10
  [reporter]=20
  [developer]=30
  [maintainer]=40
  [owner]=50
)

PAT_HDR=(-H "PRIVATE-TOKEN: $GITLAB_ADMIN_PAT")

curl_gl() {
  # Wrapper: -sk + auth header + endpoint built from $1 onwards
  curl -sk "${PAT_HDR[@]}" "$@"
}

log() { echo "$(date -u +%T) $*"; }

# --- Sanity: GitLab reachable + PAT works ---
log "==> Probing $GITLAB_URL/api/v4/version (auth check)..."
ver=$(curl_gl "$GITLAB_URL/api/v4/version" 2>/dev/null | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d.get("version", d))' 2>&1 || true)
if [[ "$ver" == *"message"* || -z "$ver" ]]; then
  echo "ERROR: GitLab API not reachable or PAT invalid. Got: $ver" >&2
  exit 1
fi
log "    GitLab $ver — auth OK"
echo

# --- Per-persona: create user if missing ---
declare -A USER_ID
IFS=',' read -ra PERSONAS_ARR <<< "$DEMO_PERSONAS"
for u in "${PERSONAS_ARR[@]}"; do
  full_name="${PERSONA_FULLNAME[$u]:-$u (demo persona)}"
  email="$u@$DEMO_EMAIL_DOMAIN"

  log "==> Persona: $u ($full_name) <$email>"
  existing=$(curl_gl "$GITLAB_URL/api/v4/users?username=$u" 2>/dev/null | python3 -c '
import sys, json
arr = json.load(sys.stdin)
print(arr[0]["id"] if arr else "")
' 2>&1 || true)

  if [[ -n "$existing" && "$existing" != *"message"* ]]; then
    USER_ID[$u]=$existing
    log "    exists (id=$existing) — skipping create"
  else
    log "    creating..."
    resp=$(curl_gl -X POST \
      -H "Content-Type: application/json" \
      -d "$(python3 -c "
import json
print(json.dumps({
  'email': '$email',
  'username': '$u',
  'name': '$full_name',
  'skip_confirmation': True,
  'force_random_password': True,
  'extern_uid': '$u',          # Keycloak preferred_username
  'provider': 'openid_connect' # matches GitLab Omnibus OIDC provider name
}))")" \
      "$GITLAB_URL/api/v4/users" 2>/dev/null)
    new_id=$(echo "$resp" | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d.get("id",""))' 2>&1)
    if [[ -z "$new_id" ]]; then
      log "    CREATE FAILED: $resp"
      continue
    fi
    USER_ID[$u]=$new_id
    log "    created id=$new_id, Keycloak SSO identity linked"
  fi
done
echo

# --- Project membership ---
IFS=',' read -ra PROJ_ARR <<< "$DEMO_PROJECTS"
for proj in "${PROJ_ARR[@]}"; do
  enc_proj=$(echo -n "$proj" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')
  log "==> Project: $proj"

  proj_id=$(curl_gl "$GITLAB_URL/api/v4/projects/$enc_proj" 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get("id",""))' 2>&1)
  if [[ -z "$proj_id" || "$proj_id" == "None" ]]; then
    log "    NOT FOUND — skipping (the project may be created later by Terraform's GitLab provider or by alice via UI)"
    continue
  fi
  log "    id=$proj_id"

  for u in "${!USER_ID[@]}"; do
    role="${PERSONA_ROLE[$u]:-developer}"
    if [[ "$role" == "admin" ]]; then
      continue   # demoadm handled by gitlab-promote-demoadmins.sh, not per-project
    fi
    uid="${USER_ID[$u]}"
    [[ -z "$uid" ]] && continue

    # Skip self-namespace owners (alice on alice/artemis-sim) — they're owner already
    proj_owner=$(curl_gl "$GITLAB_URL/api/v4/projects/$proj_id" 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get("namespace",{}).get("path",""))' 2>&1)
    if [[ "$proj_owner" == "$u" ]]; then
      log "    $u is namespace owner — skipping membership"
      continue
    fi

    level_int="${LEVEL[$role]:-30}"
    resp=$(curl_gl -X POST \
      -H "Content-Type: application/json" \
      -d "{\"user_id\": $uid, \"access_level\": $level_int}" \
      "$GITLAB_URL/api/v4/projects/$proj_id/members" 2>/dev/null)
    code=$(echo "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("access_level") or d.get("message",""))')
    log "    $u → $role (level $level_int): $code"
  done
done
echo

# --- Promote admin-tier personas to GitLab instance admin ---
log "==> Promoting admin personas to GitLab instance admin via gitlab-promote-demoadmins.sh"
if [[ -x "$(dirname "$0")/gitlab-promote-demoadmins.sh" ]]; then
  GITLAB_ADMIN_PAT="$GITLAB_ADMIN_PAT" GITLAB_URL="$GITLAB_URL" \
    "$(dirname "$0")/gitlab-promote-demoadmins.sh" 2>&1 | sed 's/^/    /'
else
  log "    NOTE: gitlab-promote-demoadmins.sh not found or not executable; admin promotion skipped"
fi

echo
log "Done."
log "Personas now exist in GitLab with Keycloak OIDC identities linked. On first"
log "SSO login (via Keycloak), GitLab's omniauth_auto_link_user binds the SSO"
log "session to the pre-existing user — no duplicate-account issues."
