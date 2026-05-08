#!/usr/bin/env bash
# Claude Code post-install configuration script.
# Called by the Coder claude-code module after installing the CLI.
# Writes ~/.claude/settings.json with AI Bridge endpoints and user identity,
# using the SETTINGS and HOME_FOLDER variables injected by the module.
set -euo pipefail

mkdir -p '${HOME_FOLDER}/.claude'
echo '${SETTINGS}' | jq | tee '${HOME_FOLDER}/.claude/settings.json' >/dev/null
