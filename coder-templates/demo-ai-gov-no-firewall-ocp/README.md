# Demo: AI Gov (no firewall)

Companion to **Demo: AI Gov (with firewall)**. Identical toolchain (Claude Code
+ Codex + code-server), same pre-cloned demo repo (`lab/cool-project`), same
Coder **AI Gateway** auth — but **no Coder Agent Firewall**.

Use this template to show what AI coding agents can reach when governance isn't
in place, then run the same commands in the firewalled variant to show the
contrast.

---

## Usage guide (run the demo in 30 seconds)

The "baseline" side of a two-template comparison. Run this demo first; it
succeeds. Then run the same prompt in **Demo: AI Gov (with firewall)**; it
fails.

**Handy reference tabs:**

- **The demo repo:** <https://gitlab.zambruhni.com/lab/cool-project>
- **The firewall allowlist (for the firewalled variant):** `demo-ai-gov-firewall-ocp/boundary.config.yaml.tftpl`
- **Firewall dashboard** (deployment-specific Grafana; silent for this template — nothing is filtering)

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

Switch to **Demo: AI Gov (with firewall)** and run the exact same prompt. There,
`registry.npmjs.org` isn't on the firewall allowlist, so boundary drops the
connection and `npm install` fails fast. Watch the DENY event land live on the
firewall dashboard.

That contrast is the whole point of this pair of templates: the agent behavior
is identical; only the network boundary is different.

---

## Why this matters

Without a firewall, the only thing between a prompt-injected / compromised /
mis-directed agent and the public internet is the agent's own alignment. That's
often enough — smaller / older models have varying reliability there, and a
sufficiently clever prompt injection can slip past even strong models. A
network-layer allowlist is the control that always works, regardless of which
model the agent is running or how it's been directed.

The npm install is the simplest possible proof that the allowlist matters: one
prompt, one `npm install`, and on the firewalled variant the install just
doesn't happen.

---

## What's included

| Tool | Access | Source | Description |
|---|---|---|---|
| VS Code Desktop | Built-in `display_app` | — | Connects the user's local VS Code |
| code-server | Browser (subdomain) | `coder/code-server` (v1.3.1) | VS Code in the browser |
| Terminal | Built-in `display_app` | — | Web terminal |
| Claude Code | Terminal / launcher | `coder/claude-code` (v5.4.0) | Anthropic CLI agent (native install) |
| Codex | Terminal / launcher | `coder-labs/codex` (v5.3.2, codex `0.159.2`) | OpenAI CLI agent (pinned binary) |

Claude Code and Codex install via their official Coder Registry modules; the
template adds clickable **Claude Code** / **Codex** launchers via its own
`coder_app` resources. Other modules: `dotfiles` (v1.4.1), `git-clone` (v1.2.3).

| Default model | Value |
|---|---|
| Claude Code (`anthropic_model`) | `global.anthropic.claude-haiku-4-5-20251001-v1:0` (Haiku 4.5) |
| Codex (`openai_model`) | `us.openai.gpt-5.6-luna` |

## AI Gateway

All AI tools authenticate through the Coder **AI Gateway** — no external API
keys needed. The gateway routes by **provider NAME** under
`/api/v2/ai-gateway/<provider>`. The workspace owner's Coder session token is
injected via `coder_env` as `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`:

| Variable | Value |
|---|---|
| `ANTHROPIC_BASE_URL` | `<access_url>/api/v2/ai-gateway/bedrock` |
| `ANTHROPIC_API_KEY` | session token |
| `ANTHROPIC_MODEL` | `var.anthropic_model` (set by the `claude-code` module) |
| `OPENAI_BASE_URL` | `<access_url>/api/v2/ai-gateway/openai-compat/v1` |
| `OPENAI_API_KEY` | session token |

Codex's `~/.codex/config.toml` (written by the module from `base_config_toml`)
sets `web_search = "disabled"` — Bedrock's OpenAI endpoint rejects the hosted
web_search tool and closes the stream mid-turn — plus
`sandbox_mode = "danger-full-access"` and `wire_api = "responses"`.

## Architecture

- **Image:** `${var.image_registry}/ubi9-node-workspace:latest` (OpenShift internal registry, mirrored from GHCR)
- **Pod:** single container; UID injected by the restricted-v2 SCC (`uid_entrypoint`)
- **Storage:** ReadWriteOnce PVC at `/home/coder`
- **Anti-affinity:** soft preference to spread workspaces across nodes
- **Dotfiles default:** `https://github.com/ausbru87/dotfiles` (branch `demo`) — editable per-workspace
- **Auto-cloned repo default:** `https://gitlab.zambruhni.com/lab/cool-project.git` — the shared demo SDK; clear `git_repo` to skip

## Deploying

```bash
cd coder-templates/demo-ai-gov-no-firewall-ocp
coder templates push demo-ai-gov-no-firewall-ocp \
  --directory . \
  --variable namespace=coder-workspaces \
  --variable image_registry=image-registry.openshift-image-registry.svc:5000/coder-workspaces \
  --yes
```

Existing running workspaces don't auto-update — they stay on whatever version
they were created from until stopped and restarted.
