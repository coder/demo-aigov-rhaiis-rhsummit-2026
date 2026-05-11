# Demo: AI Gov (no firewall)

Companion to **Demo: AI Gov (with firewall)**. Identical toolchain (Claude Code + Codex + code-server), same pre-cloned demo repo (`lab/cool-project`), same AI Bridge auth — but **no Coder Agent Firewall**.

Use this template to show what AI coding agents can reach when governance isn't in place, then run the same commands in the firewalled variant to show the contrast.

---

## Usage guide (run the demo in 30 seconds)

The "baseline" side of a two-template comparison. Run this demo first; it succeeds. Then run the same prompt in **Demo: AI Gov (with firewall)**; it fails.

**Handy reference tabs:**

- **The demo repo:** <https://gitlab.zambruhni.com/lab/cool-project>
- **The firewall allowlist (for the firewalled variant):** [boundary.config.yaml.tftpl](https://gitlab.zambruhni.com/lab/coder-templates/-/blob/main/templates/demo-ai-gov-firewall/boundary.config.yaml.tftpl?ref_type=heads)
- **Firewall dashboard (will be silent for this template — nothing's filtering):** <https://grafana.zambruhni.com/d/agent-boundaries/coder-agent-boundaries>

### Steps

1. **Create a workspace from this template.** Click **Create Workspace** → pick **Demo: AI Gov (no firewall)** → accept the defaults → wait ~60 seconds.
2. **Open the workspace's Terminal and run:**

   ```bash
   cd ~/cool-project
   claude
   ```

3. **Paste into the agent:**

   ```
   Install the express package from npm for this project
   ```

   Claude runs `npm install express`. Package downloads, project gets a `node_modules/`, agent reports success. Nothing is stopping it — this is the "yeah, that's what you expect" moment.

4. **Same thing with Codex:**

   ```bash
   codex "Install the express package from npm for this project"
   ```

   Same outcome: the package lands.

### The follow-up

Switch to **Demo: AI Gov (with firewall)** and run the exact same prompt. There, `registry.npmjs.org` isn't on the firewall allowlist, so boundary drops the connection and `npm install` fails fast. Watch the DENY event land live on the Grafana dashboard.

That contrast is the whole point of this pair of templates: the agent behavior is identical; only the network boundary is different.

---

## Why this matters

Without a firewall, the only thing between a prompt-injected / compromised / mis-directed agent and the public internet is the agent's own alignment. That's often enough — smaller / older models have varying reliability there, and a sufficiently clever prompt injection can slip past even strong models. A network-layer allowlist is the control that always works, regardless of which model the agent is running or how it's been directed.

The npm install is the simplest possible proof that the allowlist matters: one prompt, one `npm install`, and on the firewalled variant the install just doesn't happen.

---

## What's included

| Tool | Access | Description |
|---|---|---|
| VS Code Desktop | Built-in `display_app` | Connects the user's local VS Code |
| code-server | Browser (subdomain) | VS Code in the browser |
| Terminal | Built-in `display_app` | Web terminal |
| Claude Code | Terminal | Anthropic CLI agent |
| Codex | Terminal | OpenAI CLI agent |

## AI Bridge

All AI tools authenticate through Coder AI Bridge — no external API keys needed. The workspace owner's Coder session token is injected as `CLAUDE_API_KEY` and `OPENAI_API_KEY`, and requests are proxied through the Coder server.

## Architecture

- **Image:** `codercom/enterprise-node:ubuntu`
- **Pod:** single container, UID 1000
- **Storage:** ReadWriteOnce PVC at `/home/coder`
- **Anti-affinity:** soft preference to spread workspaces across nodes
- **Dotfiles default:** `https://gitlab.zambruhni.com/lab/dotfiles` (branch `main`) — editable per-workspace
- **Auto-cloned repo default:** `https://gitlab.zambruhni.com/lab/cool-project` — the shared demo SDK

## Deploying

Committed changes to `templates/demo-ai-gov-no-firewall/` are picked up by the GitLab CI pipeline:

1. **Validate** — `terraform fmt -check`, `init`, `validate`, `plan` on every MR
2. **Push** — on `main`, `coder templates push demo-ai-gov-no-firewall` runs automatically and the new version is activated

No manual `coder templates push` needed.
