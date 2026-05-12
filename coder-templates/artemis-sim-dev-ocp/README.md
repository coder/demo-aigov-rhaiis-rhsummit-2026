# artemis-sim-dev-ocp

OCP-native development workspace for a **simulator engineer** working on
the Artemis-2 simulator (C++ runtime backend + Node/TypeScript
visualization frontend). This is the **non-AI** half of the demo
narrative — contrast with `ai-dev-ocp` (CLIs + AI Bridge) and
`agents-dev-ocp` (Coder Agents beta).

## What's Included

| Tool | Access | Description |
|---|---|---|
| code-server | Browser (subdomain) | VS Code in the browser |

Registry modules:
- **dotfiles** — defaults to `https://github.com/ausbru87/dotfiles` on `main`; editable per-workspace, clear the URL to skip
- **git-clone** — clones the repo from the `git_repo` parameter (default: Artemis-2 sim monorepo) into `/home/coder`

**No AI tooling** — no Claude Code, Codex, Gemini, or Kiro CLI; no Kiro
or Cursor IDE modules; no AI Bridge env vars; no `CLAUDE_API_KEY` /
`OPENAI_API_KEY`. The point of this template is the absence of those
things.

## Parameters

| Parameter | Default | Mutable | Description |
|---|---|---|---|
| `cpu` | 4 | yes | CPU cores (2, 4, 8) |
| `memory` | 8 | yes | Memory in GB (4, 8, 12, 16, 24) |
| `disk_size` | 20 | no | Persistent volume size in GB (10, 20, 50) |
| `git_repo` | `https://gitlab.rhsummit.coderdemo.io/alice/artemis-sim` | no | Repository to clone on start (bridge overrides per-issue) |

## Bridge integration

The sprint-ticket-to-workspace bridge service watches the self-hosted
GitLab for issues labelled with either `coder-workspace` or
`coder-workspace:artemis-sim-dev-ocp`. When it sees one assigned to a
simulator engineer, it creates a workspace from this template and
overrides `git_repo` via `rich_parameter_values` to point at the
ticket's project URL. That's how `mutable = false` on `git_repo` is
compatible with per-ticket repo binding: the bridge sets it at create
time, after which the workspace is locked to that repo for its lifetime.

## Infrastructure

- **Image:** `${var.image_registry}/ubi9-node-workspace:latest`
  (UBI 9.7-tagged, layered FROM `ubi9-base-workspace` with the C++
  toolchain — cmake / clang / gdb — added in a parallel image build).
- **Container command:** `["/usr/local/bin/uid_entrypoint", "sh", "-c", coder_agent.main.init_script]`.
- **SCC:** restricted-v2 (default). No `securityContext` / `runAsUser`
  overrides; the entrypoint handles the runtime UID injected by OCP.
- **Storage:** ReadWriteOnce PVC mounted at `/home/coder`.
- **External auth:** `gitlab` only — `GITLAB_TOKEN` and `GITLAB_USER`
  are forwarded to the agent so `git-clone` can pull private repos.

## Pushing the template

Via the GH Actions workflow (`.github/workflows/push-templates.yml`):

```bash
gh workflow run push-templates.yml -f template=artemis-sim-dev-ocp
```

Or manually with the `coder` CLI:

```bash
cd coder-templates/artemis-sim-dev-ocp
coder templates push artemis-sim-dev-ocp \
  --directory . \
  --variable "namespace=coder-workspaces" \
  --variable "image_registry=ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026" \
  --yes
```
