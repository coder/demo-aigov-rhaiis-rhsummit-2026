#!/usr/bin/env bash
#
# Idempotent label setup for the booth demo. Creates the labels the GH
# workflows depend on. Run once per repo (e.g., after cloning a fork).
#
# Requires: gh CLI authenticated (`gh auth status` shows OK).
#
# Usage:
#   ./scripts/setup-demo-labels.sh

set -euo pipefail

# repo: parent repo when run from inside this clone
REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

ensure_label() {
  local name="$1" color="$2" desc="$3"
  if gh api -H "Accept: application/vnd.github+json" "repos/${REPO}/labels/${name}" >/dev/null 2>&1; then
    gh api -X PATCH "repos/${REPO}/labels/${name}" \
      -f new_name="${name}" -f color="${color}" -f description="${desc}" \
      >/dev/null
    echo "✓ updated label: ${name}"
  else
    gh api -X POST "repos/${REPO}/labels" \
      -f name="${name}" -f color="${color}" -f description="${desc}" \
      >/dev/null
    echo "+ created label: ${name}"
  fi
}

# sprint-ticket — fires .github/workflows/sprint-ticket.yml on add/open
ensure_label "sprint-ticket" "0E8A16" \
  "Demo: triggers Coder workspace provisioning from this issue"

# Optional convenience labels. Comment out if not wanted.
ensure_label "demo"           "1D76DB" "Booth demo content"
ensure_label "rhsummit-2026"  "5319E7" "Red Hat Summit 2026 demo asset"

echo
echo "Labels ready in ${REPO}."
