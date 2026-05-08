# ai-dev

Minimal AI-focused Kubernetes development environment.

## What's Included

| Tool | Access | Description |
|---|---|---|
| code-server | Browser (subdomain) | VS Code in the browser |
| mux | Browser (subdomain) | Terminal multiplexer with AI provider UI |
| Claude Code | Terminal | Anthropic coding agent CLI |
| Codex | Terminal | OpenAI coding agent CLI |

Optional modules (enabled via parameters):
- **dotfiles** — clone and apply a dotfiles repo on start
- **git-clone** — clone a project repo into `/home/coder`

## Parameters

| Parameter | Default | Mutable | Description |
|---|---|---|---|
| `cpu` | 4 | yes | CPU cores (2, 4, 8) |
| `memory` | 8 | yes | Memory in GB (4, 8, 12, 16, 24) |
| `disk_size` | 20 | no | Persistent volume size in GB (10, 20, 50) |
| `dotfiles_url` | — | no | Git dotfiles repo URL |
| `git_repo` | — | no | Repository to clone on start |

## AI Bridge

All AI tools authenticate through Coder's AI Bridge — no external API keys needed. The workspace owner's Coder session token is injected as `CLAUDE_API_KEY` and `OPENAI_API_KEY`, and requests are proxied through the Coder server to Anthropic/OpenAI.

### Environment Variables

Set automatically on every workspace:

| Variable | Purpose |
|---|---|
| `CLAUDE_API_KEY` | Session token — Claude Code CLI auth |
| `OPENAI_API_KEY` | Session token — Codex CLI auth |
| `ANTHROPIC_BASE_URL` | AI Bridge Anthropic endpoint |
| `OPENAI_BASE_URL` | AI Bridge OpenAI endpoint |
| `ANTHROPIC_MODEL` | Default Claude model |
| `ANTHROPIC_SMALL_FAST_MODEL` | Default fast model |

### Config Files Written on Start

| File | Tool | Contents |
|---|---|---|
| `~/.claude/settings.json` | Claude Code | AI Bridge URLs, git identity, model selection |
| `~/.claude.json` | Claude Code | API key, onboarding state |
| `~/.codex/config.toml` | Codex | AI Bridge provider, sandbox settings |
| `~/.mux/providers.jsonc` | mux | Anthropic provider with AI Bridge URL |

## Infrastructure

- **Image:** `codercom/enterprise-node:ubuntu`
- **Pod:** single container, runs as UID 1000
- **Storage:** ReadWriteOnce PVC mounted at `/home/coder`
- **Anti-affinity:** soft preference to spread workspaces across nodes
