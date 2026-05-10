# ai-dev-ocp

AI-focused OpenShift workspace template. CLIs talk to Coder's AI Bridge,
which proxies Anthropic traffic to AWS Bedrock (via the `coder-server`
ServiceAccount's IRSA role) and OpenAI traffic through a central
`coder-secrets.openai-api-key` (BYOK is disabled).

## What's Included

| Tool | Access | Description |
|---|---|---|
| code-server | Browser (subdomain) | VS Code in the browser |
| Kiro IDE | Desktop (kiro:// protocol) | AWS / Anthropic coding agent IDE |
| Cursor IDE | Desktop (cursor:// protocol) | AI-powered VS Code fork |
| Claude Code | Terminal | Anthropic coding agent CLI (native installer) |
| Codex | Terminal | OpenAI coding agent CLI (npm) |
| Gemini CLI | Terminal | Google coding agent CLI (npm) |
| Kiro CLI | Terminal | AWS coding agent CLI (curl install, non-interactive) |

Registry modules:
- **dotfiles** — defaults to `https://github.com/ausbru87/dotfiles` on `main`; editable per-workspace, clear the URL to skip
- **git-clone** — clones the repo from the `git_repo` parameter into `/home/coder` if set

## Parameters

| Parameter | Default | Mutable | Description |
|---|---|---|---|
| `cpu` | 4 | yes | CPU cores (2, 4, 8) |
| `memory` | 8 | yes | Memory in GB (4, 8, 12, 16, 24) |
| `disk_size` | 20 | no | Persistent volume size in GB (10, 20, 50) |
| `git_repo` | — | no | Repository to clone on start (optional) |

(Dotfiles URL/branch are surfaced by the `dotfiles` module's own form, not as a separate `coder_parameter`.)

## AI Bridge wiring

Anthropic, OpenAI, and Google CLIs all authenticate through the AI Bridge
endpoints. The workspace owner's Coder session token is injected as
`CLAUDE_API_KEY` / `OPENAI_API_KEY`; AI Bridge validates the session and
forwards to:
- **Anthropic** → AWS Bedrock via the `cluster-coder-bedrock` IRSA role
  on the `coder-server` ServiceAccount.
- **OpenAI** → upstream `api.openai.com` using the central key in
  `coder-secrets.openai-api-key` (`CODER_AIBRIDGE_ALLOW_BYOK=false`
  forces all traffic through the central key for the audit trail).

### Environment variables on every workspace

| Variable | Source | Purpose |
|---|---|---|
| `CLAUDE_API_KEY` | `coder_env` | Session token — Claude Code CLI auth |
| `OPENAI_API_KEY` | `coder_env` | Session token — Codex CLI auth |
| `ANTHROPIC_BASE_URL` | `coder_agent.env` | `<access_url>/api/v2/aibridge/anthropic` |
| `ANTHROPIC_API_BASE` | `coder_agent.env` | Same as above (some Anthropic SDKs expect this name) |
| `OPENAI_BASE_URL` | `coder_agent.env` | `<access_url>/api/v2/aibridge/openai` |

Model is NOT in env vars — Claude Code reads `~/.claude/settings.json`
where `model` is pinned to `us.anthropic.claude-sonnet-4-20250514-v1:0`
(canonical Bedrock cross-region inference profile; the bare
`claude-sonnet-4-20250514` form 404s). Other working IDs users can pick
via `/model`:
`us.anthropic.claude-sonnet-4-6`, `us.anthropic.claude-sonnet-4-5-20250929-v1:0`,
`us.anthropic.claude-opus-4-7`, `us.anthropic.claude-opus-4-6-v1`,
`us.anthropic.claude-opus-4-5-20251101-v1:0`, `us.anthropic.claude-opus-4-1-20250805-v1:0`.
See `bedrock-model-sub.md` for the subscribed-models story.

### Config files written on start

| File | Tool | Contents |
|---|---|---|
| `~/.claude/settings.json` | Claude Code | AI Bridge URLs, git identity, model pin |
| `~/.claude.json` | Claude Code | API key, onboarding state, project trust |
| `~/.codex/config.toml` | Codex | `model_providers.aibridge` block + `profile = "aibridge"`, model `gpt-5.3-codex`, `wire_api = "responses"` |

## Infrastructure

- **Image:** `${var.image_registry}/ubi9-node-workspace:latest`
  (UBI 9.7-tagged, layered FROM `ubi9-base-workspace`). Built by
  `.github/workflows/build-images.yml` from `coder-templates/images/`.
- **Container command:** `["/usr/local/bin/uid_entrypoint", "sh", "-c", coder_agent.main.init_script]`.
  The entrypoint appends a passwd entry for the runtime UID injected by
  restricted-v2 SCC, then exec's the agent init script.
- **SCC:** restricted-v2 (default). Files in `/home/coder` are
  group-0-writable via `chgrp -R 0 + chmod -R g=u` baked into the base
  image; runtime `whoami` resolves correctly for any UID in the
  namespace's allowed range.
- **Storage:** ReadWriteOnce PVC mounted at `/home/coder`, size from
  the `disk_size` parameter.
- **Anti-affinity:** soft preference to spread workspaces across nodes.
- **Image pull secret:** `ghcr-pull` (sealed) in the
  `coder-workspaces` namespace.
