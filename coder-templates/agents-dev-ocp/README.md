# agents-dev-ocp

Workspace template designed for **Coder Agents** (chatd). The LLM runs
server-side on the Coder control plane and connects to this workspace
remotely via the agent loop's `execute` / `read_file` / `write_file` /
`edit_files` / `create_workspace` tools — so this template does NOT
include any in-workspace LLM CLI, AI Bridge env vars, or `coder_env`
API key injection.

## What's Included

| Tool | Access | Description |
|---|---|---|
| code-server | Browser (subdomain) | VS Code in the browser |

That's it for browsable IDEs. No Mux, no Cursor, no Kiro IDE — agent
work happens via the chatd UI in the Coder dashboard, not via a desktop
IDE on the workspace.

System packages (installed at startup against the UBI9 base):
- Pre-baked in `ubi9-node-workspace`: git, curl, wget, jq, sudo,
  openssh-clients, python3.11/pip, gcc/make, tar/unzip/vim, Node 22, corepack
- Added at startup from EPEL 9 (tolerant — failures don't break the
  workspace): ripgrep, fd-find, tree, shellcheck, inotify-tools,
  nmap-ncat, bind-utils, lsof, procps-ng

Registry modules:
- **dotfiles** — opt-in via the `dotfiles_url` parameter (no default)
- **git-clone** — clones the repo from the `git_repo` parameter into `/home/coder` if set

## Parameters

| Parameter | Default | Mutable | Description |
|---|---|---|---|
| `cpu` | 4 | yes | CPU cores (2, 4, 8) |
| `memory` | 8 | yes | Memory in GB (4, 8, 12, 16, 24) |
| `disk_size` | 20 | no | Persistent volume size in GB (10, 20, 50) |
| `dotfiles_url` | — | no | Git dotfiles repo URL (optional) |
| `git_repo` | — | no | Repository to clone on start (optional) |

## How agents reach this workspace

Coder Agents chats run in the Coder UI. When a user picks `agents-dev-ocp`
as the workspace template and starts a chat, chatd:
1. Provisions the workspace (this template).
2. Connects to the workspace agent over Coder's tunnel.
3. Issues OpenAI-format tool calls to the configured chat model
   (Anthropic via Bedrock, or RHAIIS-hosted Qwen via openai-compat).
4. Executes the tool calls against the workspace agent — `execute` runs
   commands, `read_file` reads files, `write_file` / `edit_files` make
   code changes, `create_workspace` provisions sub-workspaces, etc.

Provider + model registration is bootstrapped by the `coder-agents-config`
Argo Job — see `manifests/coder-agents-config/README.md`.

## Infrastructure

- **Image:** `${var.image_registry}/ubi9-node-workspace:latest` (UBI 9.7).
- **Container command:** `["/usr/local/bin/uid_entrypoint", "sh", "-c", coder_agent.main.init_script]` — same SCC-compliant entrypoint pattern as `ai-dev-ocp`.
- **SCC:** restricted-v2 (default).
- **Storage:** ReadWriteOnce PVC at `/home/coder`.
- **Image pull secret:** `ghcr-pull` (sealed) in `coder-workspaces`.
