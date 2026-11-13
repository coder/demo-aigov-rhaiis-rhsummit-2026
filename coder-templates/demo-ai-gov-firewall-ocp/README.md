# Demo: AI Governance + Agent Firewall (OpenShift)

A Coder workspace template that demonstrates **governed AI agents** on OpenShift.

## What you get

- **Coder AI Gateway:** Claude Code and Codex authenticate with the workspace owner's
  Coder session token (no external API keys); every request is captured in the
  **AI Session logs**. Claude Code → `bedrock`; Codex → `smart-router`, which the gateway
  proxies to the **Smart Router** (vLLM Semantic Router, model `vllm-sr/auto`).
- **Coder Agent Firewall (`boundary`):** every AI CLI runs inside a default-deny network
  jail — only hosts on the allowlist are reachable. Edit the allowlist in
  `boundary.config.yaml.tftpl`.
- **IDEs / CLIs:** code-server, VS Code Desktop, web Terminal, Claude Code, Codex.

## Create the template

```bash
coder templates push demo-ai-gov-firewall-ocp -d .
```

Variables: `namespace` (default `coder-workspaces`) and `image_registry` (default the
in-cluster OpenShift registry).

## Demo flow

1. Create a workspace from the template. The sample project repo
   `https://gitlab.rhsummit.coderdemo.io/demoadm/memorycard.git` is cloned on start.
2. **Governance:** run an agent task with `codex` or `claude`, then open the
   **AI Session logs** (`/admin/ai-governance`) and show the captured activity.
3. **Firewall:** ask the agent to reach a host that is **not** on the allowlist (an
   exfiltration attempt). `boundary` blocks the connection — watch the DENY events in
   `/tmp/boundary_logs/`. A ready-made test is staged at `~/demo/exfil-test.sh`.

## Notes

- `boundary` uses the `landjail` backend (Linux Landlock); nsjail does not work on
  OCP 4.21 + OVN-Kubernetes.
- Dotfiles are applied on start from `https://github.com/ausbru87/dotfiles` (`main`).
  Clear the dotfiles URL per-workspace to skip.
