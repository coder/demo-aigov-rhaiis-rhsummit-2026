# AI Dev Environment (OpenShift)

A Coder workspace template for AI-assisted development on OpenShift/Kubernetes.

## What you get

- **IDEs:** code-server (VS Code in the browser) + VS Code Desktop
- **AI CLIs:** Claude Code and Codex (plus Gemini and Kiro)
- **Governed AI routing:** both CLIs go through the **Coder AI Gateway** using the
  workspace owner's session token, so every request is captured in the **AI Session
  logs**. Claude Code → `bedrock` provider; Codex → `smart-router` provider, which
  the gateway proxies to the **Smart Router** (vLLM Semantic Router, model
  `vllm-sr/auto`) to classify and route each request to the right local or burst model.

## Create the template

```bash
coder templates push ai-dev-ocp -d .
```

Variables: `namespace` (default `coder-workspaces`) and `image_registry` (default the
in-cluster OpenShift registry).

## Demo flow

1. Create a workspace from the template in the Coder dashboard.
2. Open **code-server** (or VS Code Desktop) and a terminal.
3. Run an agent task with **Codex** (`codex`) or **Claude Code** (`claude`) — for example,
   clone `https://gitlab.rhsummit.coderdemo.io/demoadm/memorycard.git` and ask the agent
   to extend it.
4. Open the **AI Session logs** (`/admin/ai-governance`) and show the activity captured
   and attributed to the user.

## Dotfiles

Personal dotfiles are applied on start from `https://github.com/ausbru87/dotfiles`
(`main`). Clear the dotfiles URL per-workspace to skip.
