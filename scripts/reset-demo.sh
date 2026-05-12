#!/usr/bin/env bash
# Reset per-event demo state.
#
# What it touches
# ---------------
# For each Keycloak demo persona listed in $DEMO_PERSONAS:
#   - Deletes every Coder workspace they own.
#   - Deletes every Coder Agents chat they own.
#
# For each GitLab project listed in $DEMO_PROJECTS:
#   - Deletes every issue (open OR closed). This frees up the
#     iid counter so the next booth visitor opens an issue at #1,
#     not at #47.
#
# Then re-promotes any Keycloak `admins`-group personas to GitLab
# instance admin via gitlab-promote-demoadmins.sh (idempotent — only
# acts on users that need it).
#
# What it does NOT touch
# ----------------------
# - Keycloak users / passwords / group memberships
#   (those are part of the realm-demo.yaml IaC; they survive a reset
#    so alice is still alice with the same password).
# - GitLab projects themselves (only the issues inside).
# - GitLab repository content (preserved — booth flow expects a real
#   repo to exist).
# - The bridge service, vLLM, Coder server, chatd model configs,
#   prompts — all stable infrastructure.
# - Cluster IaC (Argo applications, MachineSets, etc.).
# - Templates pushed via `coder templates push`.
#
# Usage
# -----
#   ./scripts/reset-demo.sh --plan       # dry run — shows what would be deleted, makes NO changes
#   ./scripts/reset-demo.sh              # interactive — lists what'll be deleted, then prompts y/N
#   ./scripts/reset-demo.sh --confirm    # non-interactive — deletes everything immediately
#
# Env vars (with defaults):
#   DEMO_PERSONAS=alice,bob,demoadm
#   DEMO_PROJECTS=alice/artemis-sim
#   CODER_URL=https://coder.apps.cluster.rhsummit.coderdemo.io
#   GITLAB_API=https://gitlab.rhsummit.coderdemo.io/api/v4
#
# Requires admin kube context (so the Coder admin token can be read
# from the SealedSecret) + SSH to the GitLab EC2 host (for the
# admin PAT mint via gitlab-rails runner).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

DEMO_PERSONAS="${DEMO_PERSONAS:-alice,bob,demoadm}"
DEMO_PROJECTS="${DEMO_PROJECTS:-alice/artemis-sim}"
CODER_URL="${CODER_URL:-https://coder.apps.cluster.rhsummit.coderdemo.io}"
GITLAB_API="${GITLAB_API:-https://gitlab.rhsummit.coderdemo.io/api/v4}"

MODE="interactive"
case "${1:-}" in
  --plan)    MODE="plan";;
  --confirm) MODE="confirm";;
  "")        MODE="interactive";;
  *)         echo "unknown flag: $1" >&2; exit 2;;
esac

# Color helpers — booth-grade, no fancy terminfo detection.
red()    { printf '\033[31m%s\033[0m' "$*"; }
green()  { printf '\033[32m%s\033[0m' "$*"; }
yellow() { printf '\033[33m%s\033[0m' "$*"; }
gray()   { printf '\033[90m%s\033[0m' "$*"; }
bold()   { printf '\033[1m%s\033[0m' "$*"; }

log()  { echo "$(gray "[$(date -u +%H:%M:%S)]") $*"; }
plan() { echo "  $(yellow "WOULD DELETE")  $*"; }
del()  { echo "  $(red   "DELETING")     $*"; }
skip() { echo "  $(gray  "skip:")        $*"; }

# Only `--confirm` does real deletes. Both `--plan` and interactive
# mode's first pass run dry; interactive then re-execs with --confirm
# after the user types y.
dry() { [ "$MODE" != "confirm" ]; }

# --- Prerequisites ----------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  echo "$(red ERROR): jq not on PATH" >&2; exit 1
fi
if ! oc whoami >/dev/null 2>&1; then
  echo "$(red ERROR): oc not logged in — run \`oc login\` as cluster-admin first" >&2; exit 1
fi

CODER_TOKEN=$(oc -n coder get secret coder-admin-token -o jsonpath='{.data.token}' | base64 -d)
if [ -z "$CODER_TOKEN" ]; then
  echo "$(red ERROR): could not read coder-admin-token from cluster" >&2; exit 1
fi

GITLAB_IP=""
if [ -d "${TF_DIR}" ]; then
  GITLAB_IP=$(cd "${TF_DIR}" && env -u AWS_ENDPOINT_URL AWS_PROFILE=ocp-deploy-acct \
    terraform output -raw gitlab_public_ip 2>/dev/null || echo "")
fi
if [ -z "$GITLAB_IP" ]; then
  echo "$(yellow WARN): could not read gitlab_public_ip from terraform; will skip GitLab cleanup" >&2
fi

# Mint a short-lived GitLab admin PAT (only if we got the IP).
GITLAB_PAT=""
if [ -n "$GITLAB_IP" ]; then
  log "Minting 1-hour GitLab admin PAT…"
  GITLAB_PAT=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null \
    ec2-user@"$GITLAB_IP" 'sudo gitlab-rails runner "
      u = User.find_by(username: %q(root))
      t = u.personal_access_tokens.create!(scopes: [:api, :admin_mode], name: %q(demo-reset), expires_at: 1.hour.from_now)
      puts t.token
    "' 2>/dev/null | tail -1)
  if [ -z "$GITLAB_PAT" ] || [ "${GITLAB_PAT:0:6}" != "glpat-" ]; then
    echo "$(yellow WARN): failed to mint GitLab admin PAT — will skip GitLab cleanup" >&2
    GITLAB_PAT=""
  fi
fi

# --- Helpers ----------------------------------------------------------------

ch() { curl -sk -H "Coder-Session-Token: $CODER_TOKEN" -H "Accept: application/json" "$@"; }
gl() { curl -sk -H "PRIVATE-TOKEN: $GITLAB_PAT" -H "Accept: application/json" "$@"; }

# --- 1. Coder workspaces + chats per persona --------------------------------

ws_total=0; chat_total=0
IFS=',' read -ra PERSONAS <<<"$DEMO_PERSONAS"
for p in "${PERSONAS[@]}"; do
  p="$(echo "$p" | xargs)"
  [ -z "$p" ] && continue

  user_id=$(ch "$CODER_URL/api/v2/users/$p" 2>/dev/null | jq -r '.id // empty')
  if [ -z "$user_id" ]; then
    skip "Coder user '$p' not found"
    continue
  fi
  echo ""
  bold "==> $p"; echo " ($user_id)"

  # Workspaces
  ws_ids=$(ch "$CODER_URL/api/v2/workspaces?owner=$p" \
    | jq -r '.workspaces[]? | "\(.id)\t\(.name)"')
  if [ -n "$ws_ids" ]; then
    while IFS=$'\t' read -r wid wname; do
      [ -z "$wid" ] && continue
      ws_total=$((ws_total+1))
      if dry; then
        plan "Coder workspace $wname  ($wid)"
      else
        del  "Coder workspace $wname  ($wid)"
        ch -X DELETE "$CODER_URL/api/v2/workspaces/$wid?orphan=true" >/dev/null || true
      fi
    done <<<"$ws_ids"
  fi

  # Chats — only root chats (children get garbage-collected with parent)
  chat_ids=$(ch "$CODER_URL/api/experimental/chats" \
    | jq -r --arg uid "$user_id" '.[] | select(.owner_id==$uid and .parent_chat_id==null) | "\(.id)\t\(.title // "untitled")"')
  if [ -n "$chat_ids" ]; then
    while IFS=$'\t' read -r cid ctitle; do
      [ -z "$cid" ] && continue
      chat_total=$((chat_total+1))
      if dry; then
        plan "Coder chat       \"$ctitle\"  ($cid)"
      else
        del  "Coder chat       \"$ctitle\"  ($cid)"
        ch -X DELETE "$CODER_URL/api/experimental/chats/$cid" >/dev/null || true
      fi
    done <<<"$chat_ids"
  fi
done

# --- 2. GitLab issues per project -------------------------------------------

issue_total=0
if [ -n "$GITLAB_PAT" ]; then
  IFS=',' read -ra PROJECTS <<<"$DEMO_PROJECTS"
  for proj in "${PROJECTS[@]}"; do
    proj="$(echo "$proj" | xargs)"
    [ -z "$proj" ] && continue
    enc=$(printf '%s' "$proj" | jq -sRr @uri)

    project_id=$(gl "$GITLAB_API/projects/$enc" | jq -r '.id // empty')
    if [ -z "$project_id" ]; then
      skip "GitLab project '$proj' not found"
      continue
    fi
    echo ""
    bold "==> GitLab project $proj"; echo " (id $project_id)"

    # Fetch ALL issues (open + closed) — page through 100 at a time.
    page=1
    while :; do
      batch=$(gl "$GITLAB_API/projects/$project_id/issues?state=all&per_page=100&page=$page")
      count=$(echo "$batch" | jq 'length')
      [ "$count" = "0" ] && break
      while IFS=$'\t' read -r iid title; do
        [ -z "$iid" ] && continue
        issue_total=$((issue_total+1))
        if dry; then
          plan "GitLab issue #$iid  \"$title\""
        else
          del  "GitLab issue #$iid  \"$title\""
          gl -X DELETE "$GITLAB_API/projects/$project_id/issues/$iid" >/dev/null || true
        fi
      done < <(echo "$batch" | jq -r '.[] | "\(.iid)\t\(.title)"')
      page=$((page+1))
    done
  done
fi

# --- 3. Re-promote demoadm to GitLab instance admin -------------------------

if [ -n "$GITLAB_PAT" ] && ! dry; then
  echo ""
  log "Re-running gitlab-promote-demoadmins.sh (idempotent)…"
  "${REPO_ROOT}/scripts/gitlab-promote-demoadmins.sh" 2>&1 | sed 's/^/  /' || true
fi

# --- Summary + interactive confirmation -------------------------------------

echo ""
bold "Summary"; echo
echo "  Coder workspaces : $ws_total"
echo "  Coder chats      : $chat_total"
echo "  GitLab issues    : $issue_total"
if [ -z "$GITLAB_PAT" ]; then
  echo "  $(yellow "GitLab cleanup skipped — no PAT")"
fi

if [ "$MODE" = "plan" ]; then
  echo ""
  green "Dry run complete — no changes made."; echo
  echo "Run \`./scripts/reset-demo.sh\` (interactive) or \`./scripts/reset-demo.sh --confirm\` to apply."
elif [ "$MODE" = "interactive" ]; then
  echo ""
  # This branch ran a dry inventory above (because MODE wasn't "confirm");
  # now prompt the user to actually apply. We re-execute ourselves with
  # --confirm so the output is consistent with the non-interactive path.
  printf "$(red Apply these deletions?) [y/N] "
  read -r ans
  if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
    echo ""
    exec "$0" --confirm
  else
    echo "Aborted. No changes made."
  fi
else
  echo ""
  green "Reset complete."; echo
fi
