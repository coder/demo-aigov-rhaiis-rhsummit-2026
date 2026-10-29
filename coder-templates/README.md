# coder-templates/

Coder workspace templates pushed to the live Coder instance by the
`.github/workflows/push-templates.yml` workflow on every change to this
directory.

## Templates currently shipped

- **`ai-dev-ocp/`** — code-server + Kiro IDE + Cursor + Claude Code / Codex / Gemini / Kiro CLIs. Claude Code and Codex install via the official Coder Registry modules (`coder/claude-code`, `coder-labs/codex`) and route through the **Coder AI Gateway**. Defaults: Claude Opus 4.5 (`global.anthropic.claude-opus-4-5-20251101-v1:0`), Codex GPT-5.6 Sol (`us.openai.gpt-5.6-sol`).
- **`demo-ai-gov-no-firewall-ocp/`** — governance demo baseline: code-server + Claude Code + Codex (modules), AI Gateway wired, demo repo pre-cloned. No Agent Firewall — shows unrestricted agent reach.
- **`demo-ai-gov-firewall-ocp/`** — the same toolchain behind the **Coder Agent Firewall** (`boundary`, landjail backend). AI CLIs run through per-tool boundary wrappers against a default-deny allowlist. Crown-jewel demo.
- **`agents-dev-ocp/`** — code-server only. The agentic loop runs server-side via Coder Agents (chatd) talking to Bedrock + RHAIIS-hosted Qwen 2.5 Coder 32B. No AI Gateway env vars / no LLM CLIs in the workspace.
- **`artemis-sim-dev-ocp/`** — plain dev workspace (no AI wiring) for the Artemis simulation demo.

## AI Gateway routing convention

Templates that wire AI CLIs target the **Coder AI Gateway** (Coder 2.37.x),
which routes by **provider NAME** under `/api/v2/ai-gateway/<provider>`:

- Claude Code → `.../api/v2/ai-gateway/bedrock` (Anthropic Messages API)
- Codex → `.../api/v2/ai-gateway/openai-compat/v1` (OpenAI Responses API)

Auth is the workspace owner's Coder **session token**, injected via `coder_env`
(`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`); the gateway validates it and injects
the real upstream credentials. The provider-*type* aliases `/anthropic` and
`/openai` are NOT valid routes (404 "route not supported"). Codex must set
`web_search = "disabled"` — Bedrock's OpenAI endpoint rejects the hosted
web_search tool and closes the stream mid-turn.

## Conventions

- One subdirectory per template: `<template-name>/`
- Each template has:
  - `main.tf` — Coder Terraform (`coder/coder` provider)
  - `README.md` — what the template does, who it's for, env vars / params
  - `metadata.json` — display name + icon + description applied post-push by the GH Actions workflow

Workspace base images live in a SHARED tree at `coder-templates/images/`, NOT per-template:
- `ubi9-base-workspace` — UBI 9.7 + EPEL + zsh/tmux/neovim/fzf/ripgrep + starship + the SCC-compliant `uid_entrypoint.sh` pattern
- `ubi9-node-workspace` — `FROM ubi9-base-workspace` + NodeSource Node 22 + corepack + C++ toolchain + **code-server pre-baked at `/usr/lib/code-server`** (so the `-ocp` templates run it offline via the `coder/code-server` module's `offline = true` instead of downloading from `code-server.dev` on every start)
- `agents-config-tools` — UBI9-minimal + aws + jq + curl, used by the `coder-agents-config` Argo Job

Both `-ocp` templates `FROM` `ubi9-node-workspace:latest`. Built by `.github/workflows/build-images.yml` on changes under `coder-templates/images/**`.

### Air-gapped / self-contained image source (OpenShift internal registry)

GHCR is the source of truth for the images, but at workspace-create time the
`-ocp` templates pull from the **in-cluster OpenShift internal registry** so the
cluster never fetches workspace images from the public internet (supply-chain
hardening). Mirror the GHCR images into the internal registry with:

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type=merge -p '{"spec":{"defaultRoute":true}}'   # once, to expose the push route
coder-templates/images/mirror-to-internal-registry.sh
```

The templates default `image_registry` to
`image-registry.openshift-image-registry.svc:5000/coder-workspaces`. Re-run the
mirror script whenever the GHCR images are rebuilt.

## Pushing a template manually

```bash
cd coder-templates/ai-dev-ocp     # or agents-dev-ocp
coder login https://coder.<your-cluster-fqdn>
coder templates push ai-dev-ocp \
  --directory . \
  --variable namespace=coder-workspaces \
  --variable image_registry=image-registry.openshift-image-registry.svc:5000/coder-workspaces \
  --yes
```

## Pushing via GitHub Actions

Required GH secrets (set once with `gh secret set`):
- `CODER_URL` — the Coder instance URL (from `terraform output -raw coder_url`)
- `CODER_SESSION_TOKEN` — Coder session token (created via `coder tokens create` after login)

Optional GH variable:
- `IMAGE_REGISTRY` — overrides the default in-cluster registry path (`image-registry.openshift-image-registry.svc:5000/coder-workspaces`); set to a GHCR path if you want workspaces to pull directly from GHCR instead of the mirrored internal registry.

The workflow runs on push to `main` when `coder-templates/**` changes. No AWS credentials are required — image pushes use the workflow's built-in `GITHUB_TOKEN`.
