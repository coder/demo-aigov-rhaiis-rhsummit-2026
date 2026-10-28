# ai-dev-ocp

AI-focused OpenShift workspace template. The Claude Code and Codex CLIs are
installed and configured by their **official Coder Registry modules** and talk
to the **Coder AI Gateway**, which proxies Anthropic traffic to AWS Bedrock
(via the `coder-server` ServiceAccount's IRSA role) and OpenAI-compatible
traffic to Bedrock's OpenAI endpoint. Gemini and Kiro CLIs authenticate
independently.

## What's Included

| Tool | Access | Source | Description |
|---|---|---|---|
| code-server | Browser (subdomain) | `coder/code-server` module | VS Code in the browser |
| Kiro IDE | Desktop (kiro:// protocol) | `coder/kiro` module | AWS / Anthropic coding agent IDE |
| Cursor IDE | Desktop (cursor:// protocol) | `coder/cursor` module | AI-powered VS Code fork |
| Claude Code | Terminal / launcher | `coder/claude-code` module (v5.4.0) | Anthropic coding agent CLI (native install) |
| Codex | Terminal / launcher | `coder-labs/codex` module (v5.3.2) | OpenAI coding agent CLI (pinned binary, codex `0.159.2`) |
| Gemini CLI | Terminal | startup script (`npm -g @google/gemini-cli`) | Google coding agent CLI |
| Kiro CLI | Terminal | startup script (`cli.kiro.dev` installer) | AWS coding agent CLI |

Neither the `claude-code` nor the `codex` module creates a `coder_app`; this
template provides clickable **Claude Code** and **Codex** launchers under the
"AI Tools" group via its own `coder_app` resources.

Other Registry modules:
- **dotfiles** (`v1.4.1`) — defaults to `https://github.com/ausbru87/dotfiles` on `main`; editable per-workspace, clear the URL to skip
- **git-clone** (`v1.0.22`) — clones the repo from the `git_repo` parameter into `/home/coder` if set

## Parameters

| Parameter | Default | Mutable | Description |
|---|---|---|---|
| `cpu` | 4 | yes | CPU cores (2, 4, 8) |
| `memory` | 8 | yes | Memory in GB (4, 8, 12, 16, 24) |
| `disk_size` | 20 | no | Persistent volume size in GB (10, 20, 50) |
| `git_repo` | — | no | Repository to clone on start (optional) |

(Dotfiles URL/branch are surfaced by the `dotfiles` module's own form, not as a
separate `coder_parameter`.)

## Template variables (set at push time)

| Variable | Default | Purpose |
|---|---|---|
| `namespace` | `coder-workspaces` | Namespace for workspace pods |
| `image_registry` | `image-registry.openshift-image-registry.svc:5000/coder-workspaces` | Registry hosting the base images |
| `anthropic_model` | `global.anthropic.claude-opus-4-5-20251101-v1:0` | Model Claude Code requests through the gateway's `bedrock` provider |
| `openai_model` | `us.openai.gpt-5.6-sol` | Model Codex requests through the gateway's `openai-compat` provider |

## AI Gateway wiring

Claude Code and Codex authenticate through the **Coder AI Gateway**, which
routes by **provider NAME** under `/api/v2/ai-gateway/<provider>`. The
workspace owner's Coder session token is injected as the API key; the gateway
validates it and forwards to the real upstream:

- **Claude Code** → provider `bedrock` → AWS Bedrock via the IRSA role on the
  `coder-server` ServiceAccount.
- **Codex** → provider `openai-compat` → Bedrock's OpenAI-compatible
  (`/openai/v1`) endpoint.

> The module option `enable_ai_gateway` is deliberately **not** used — its
> generic `/anthropic` route and `ANTHROPIC_AUTH_TOKEN` don't match our
> provider-named `bedrock` route. We wire the gateway via `coder_env` instead.

### Environment variables on every workspace

| Variable | Source | Value |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `coder_env` | `<access_url>/api/v2/ai-gateway/bedrock` |
| `ANTHROPIC_API_KEY` | `coder_env` | Workspace owner's Coder session token |
| `ANTHROPIC_MODEL` | `coder/claude-code` module | `var.anthropic_model` |
| `OPENAI_BASE_URL` | `coder_env` | `<access_url>/api/v2/ai-gateway/openai-compat/v1` |
| `OPENAI_API_KEY` | `coder_env` | Workspace owner's Coder session token |

### Config files written on start

| File | Tool | Written by | Contents |
|---|---|---|---|
| `~/.claude/settings.json` | Claude Code | startup script | Permission bypass + model picker locked to the gateway's provisioned Anthropic models (Opus 4.5, Haiku 4.5) |
| `~/.claude.json` | Claude Code | `coder/claude-code` module | Install/onboarding state |
| `~/.codex/config.toml` | Codex | `coder-labs/codex` module (`base_config_toml`) | `model_providers.openai-compat` block, `wire_api = "responses"`, model `us.openai.gpt-5.6-sol`, `web_search = "disabled"`, `sandbox_mode = "danger-full-access"` |

**Codex `web_search = "disabled"`** is required: Codex attaches a hosted
web_search tool by default, which Bedrock's OpenAI endpoint rejects ("web
search is not supported for this request"), closing the stream mid-turn.

## Infrastructure

- **Image:** `${var.image_registry}/ubi9-node-workspace:latest`
  (UBI 9.7-tagged, layered FROM `ubi9-base-workspace`). Built by
  `.github/workflows/build-images.yml` from `coder-templates/images/`.
- **Container command:** `["/usr/local/bin/uid_entrypoint", "sh", "-c", coder_agent.main.init_script]`.
  The entrypoint appends a passwd entry for the runtime UID injected by
  restricted-v2 SCC, then exec's the agent init script.
- **SCC:** restricted-v2 (default). Native CLI installs (no npm sudo) keep the
  workspace compatible with the restricted SCC. Files in `/home/coder` are
  group-0-writable via `chgrp -R 0 + chmod -R g=u` baked into the base image.
- **Storage:** ReadWriteOnce PVC mounted at `/home/coder`, size from the
  `disk_size` parameter.
- **Anti-affinity:** soft preference to spread workspaces across nodes.

## Pushing

```bash
cd coder-templates/ai-dev-ocp
coder templates push ai-dev-ocp \
  --directory . \
  --variable namespace=coder-workspaces \
  --variable image_registry=image-registry.openshift-image-registry.svc:5000/coder-workspaces \
  --yes
```
