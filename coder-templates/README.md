# coder-templates/

Coder workspace templates pushed to the live Coder instance by the
`.github/workflows/push-templates.yml` workflow on every change to this
directory.

## Templates currently shipped

- **`ai-dev-ocp/`** — code-server + Kiro IDE + Cursor + Claude Code / Codex / Gemini / Kiro CLIs. AI Bridge wired (Anthropic via Bedrock IRSA, OpenAI via central key). Pinned Claude model is the canonical Bedrock inference profile `us.anthropic.claude-sonnet-4-20250514-v1:0`.
- **`agents-dev-ocp/`** — code-server only. The agentic loop runs server-side via Coder Agents (chatd) talking to Bedrock + RHAIIS-hosted Qwen 2.5 Coder 32B. No AI Bridge env vars / no LLM CLIs in the workspace.

## Conventions

- One subdirectory per template: `<template-name>/`
- Each template has:
  - `main.tf` — Coder Terraform (`coder/coder` provider)
  - `README.md` — what the template does, who it's for, env vars / params
  - `metadata.json` — display name + icon + description applied post-push by the GH Actions workflow

Workspace base images live in a SHARED tree at `coder-templates/images/`, NOT per-template:
- `ubi9-base-workspace` — UBI 9.7 + EPEL + zsh/tmux/neovim/fzf/ripgrep + starship + the SCC-compliant `uid_entrypoint.sh` pattern
- `ubi9-node-workspace` — `FROM ubi9-base-workspace` + NodeSource Node 22 + corepack
- `agents-config-tools` — UBI9-minimal + aws + jq + curl, used by the `coder-agents-config` Argo Job

Both `-ocp` templates `FROM` `ubi9-node-workspace:latest`. Built by `.github/workflows/build-images.yml` on changes under `coder-templates/images/**`.

## Pushing a template manually

```bash
cd coder-templates/ai-dev-ocp     # or agents-dev-ocp
coder login https://coder.<your-cluster-fqdn>
coder templates push ai-dev-ocp \
  --directory . \
  --variable namespace=coder-workspaces \
  --variable image_registry=ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026 \
  --yes
```

## Pushing via GitHub Actions

Required GH secrets (set once with `gh secret set`):
- `CODER_URL` — the Coder instance URL (from `terraform output -raw coder_url`)
- `CODER_SESSION_TOKEN` — Coder session token (created via `coder tokens create` after login)

Optional GH variable:
- `IMAGE_REGISTRY` — overrides the default `ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026` registry path (use this if you fork the repo into another GH org)

The workflow runs on push to `main` when `coder-templates/**` changes. No AWS credentials are required — image pushes use the workflow's built-in `GITHUB_TOKEN`.
