# Demo: AI Gov (with firewall)

A live demonstration of [Coder Agent Firewall](https://coder.com/docs/ai-coder/agent-firewall). AI coding agents in this workspace run behind a default-deny network boundary — they can call AI providers and approved package registries, and nothing else.

> [!TIP]
> The companion template **Demo: AI Gov (no firewall)** runs the same toolchain *without* the firewall. Run the demos on that template first to show the agent's unrestricted behavior, then here to show the firewall stepping in.

---

## Usage guide (run the demo in 90 seconds)

Two demos, increasing in realism. Part 1 is a 15-second "does the firewall work?" smoke test. Part 2 is the full "realistic supply-chain attack" walkthrough.

**Handy reference tabs to keep open during a demo:**

- **Firewall dashboard:** deployment-specific Grafana (coder-observability) — live DENY events
- **The demo repo:** <https://gitlab.zambruhni.com/lab/cool-project> (the project the agent will try to set up in Part 2)
- **The allowlist file:** `boundary.config.yaml.tftpl` (next to `main.tf`) — what's allowed vs blocked (e.g. npm intentionally NOT on the list)

### Setup (both parts)

1. **Open the Grafana dashboard in a second browser tab.** Leave it on screen — you'll watch DENY events land live as the agent works.
2. **Create a workspace from this template.** Click **Create Workspace** → pick **Demo: AI Gov (with firewall)** → accept the defaults → wait ~60 seconds.
3. **Open the workspace's Terminal.**

### Part 1 — the quick obvious block: npm is not allowlisted

```bash
cd ~/cool-project
claude
```

Then paste into the agent:

```
Install the express package from npm for this project
```

Claude (on Haiku, prompt-free) runs `npm install express`. `registry.npmjs.org` is **not** on the firewall allowlist, so boundary drops the connection and npm errors out almost immediately. A DENY event lands on the Grafana dashboard; you can point at it and say "this is the firewall refusing a package install from an unapproved registry."

This is the simplest possible demo — it proves the firewall is in the path, in under 15 seconds, with no narrative setup required.

### Part 2 — the realistic supply-chain attack via cool-project

Still in the Claude session, paste:

```
Help me set up this project for development
```

Claude reads `CLAUDE.md` in `~/cool-project`, runs `make setup`, and tries to pull dependencies from hosts that aren't on the allowlist. This time the blocked hosts look legitimate — a private PyPI mirror, a CDN for "cool-project" binaries, an analytics endpoint. Boundary drops them all. Watch the DENY events land; the agent fixes some real bugs (typos, a bogus build backend) along the way but can't finish the install, because the failures are network-level and it can't engineer around them.

**Same Part 2 demo with Codex:**

```bash
codex "Help me set up this project for development"
```

Codex reads `AGENTS.md` and follows the same flow.

### What you're seeing across both parts

- The agent reads project instructions and runs shell commands without asking for confirmation (`--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox`).
- Every outbound HTTP/HTTPS request goes through boundary; anything not on the allowlist is dropped before it leaves the pod.
- The agent tries to work around the errors, but the network boundary isn't something it can engineer around.

The story: **the agent's good intentions don't have to be trusted.** The firewall is what the trust rests on.

---

## How the firewall works

`boundary` (v0.9.0) runs each AI CLI under the **landjail** backend (Linux
Landlock LSM): the wrapped process can only reach hosts on the allowlist; a
transparent HTTP/HTTPS proxy reads `~/.config/coder_boundary/config.yaml` and
either forwards or drops each request:

```
agent ──▶ boundary proxy ──┬──▶ allowed host   (log: allow)
                           └──X denied host    (log: deny)
```

> [!NOTE]
> We use **landjail**, not boundary's default **nsjail**. nsjail does NOT work
> on OpenShift 4.21 / OVN-Kubernetes: the pod's `ip_forward` sysctl is 0, so
> nsjail's MASQUERADE NAT rule has nowhere to forward packets ("No route to
> host"). landjail uses Landlock — no network namespace, no iptables, no
> privileged setup. The wrappers pass `--jail-type landjail` explicitly and
> `BOUNDARY_JAIL_TYPE=landjail` is exported in the shell profiles.

> [!IMPORTANT]
> The agent's **`WebFetch` / `WebSearch` tools run server-side** — the HTTP
> request originates from the AI provider's infrastructure, not the workspace
> pod. Boundary never sees those requests and cannot filter them. Only things
> the agent runs via its **`Bash` tool** (curl, git, pip, npm, any subprocess)
> go through boundary.

## Access points

Three, intentionally:

| Entry | Source | Description |
|---|---|---|
| VS Code Desktop | built-in `display_app` | Local VS Code over SSH |
| code-server | `coder/code-server` module | VS Code in the browser |
| Terminal | built-in `display_app` | Web terminal |

All other built-in display apps (VS Code Insiders, SSH helper, port-forwarding helper) are explicitly disabled on the agent to keep the UI focused.

## AI CLIs

Two installed, both authenticated through the Coder **AI Gateway** — no
external API keys needed. The gateway routes by **provider NAME** under
`/api/v2/ai-gateway/<provider>`; the workspace owner's session token is
injected via `coder_env` as `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`.

| CLI | Install (Coder Registry module) | Default model |
|---|---|---|
| Claude Code | `coder/claude-code` v5.4.0 — native installer | `global.anthropic.claude-haiku-4-5-20251001-v1:0` (Haiku 4.5) |
| Codex | `coder-labs/codex` v5.3.2 — pinned standalone binary (codex `0.159.2`) | `us.openai.gpt-5.6-luna` |

Both CLIs are installed **natively** (no npm/sudo), which keeps the workspace
compatible with OpenShift's restricted SCC model. The modules install the
binaries asynchronously; the startup script **waits** for both before building
the boundary wrappers (see below). Codex's `~/.codex/config.toml` is written by
its module from `base_config_toml` and sets `web_search = "disabled"` (Bedrock's
OpenAI endpoint rejects the hosted web_search tool and closes the stream),
`sandbox_mode = "danger-full-access"`, and `wire_api = "responses"`.

Gemini CLI and Kiro CLI aren't installed: the AI Gateway doesn't currently
support them (Gemini — [coder/aibridge#27](https://github.com/coder/aibridge/issues/27); Kiro — no base-URL override).

## Wrapper behavior

Every AI CLI invocation goes through a wrapper script at `~/.local/bin/boundary-wrappers/<tool>` that calls `boundary -- <real-binary> <default-flags> "$@"`. The wrappers dir is prepended to `PATH` in `~/.profile`, `~/.bashrc`, `~/.zshrc`, and `~/.zprofile`. The `dotfiles` module's `post_clone_script` re-applies the `PATH` export after user dotfiles are cloned, so dotfiles that wholesale-replace `~/.zshrc` (oh-my-zsh, prezto) don't break the wrappers.

Default args the wrappers inject:

- `claude` → `--dangerously-skip-permissions --model global.anthropic.claude-haiku-4-5-20251001-v1:0`
- `codex` → *(none)* — model, approval policy, and sandbox mode all come from `~/.codex/config.toml` (`approval_policy = "never"`, `sandbox_mode = "danger-full-access"`, model `us.openai.gpt-5.6-luna`)

### Running against a stronger model / bypassing the wrapper

The wrappers are convenience, not enforcement. Call the real binary with your own flags:

```bash
/home/coder/.local/bin/claude --model global.anthropic.claude-opus-4-5-20251101-v1:0
/home/coder/.local/bin/codex --model us.openai.gpt-5.6-sol
```

To completely bypass boundary AND the default flags (debugging only):

```bash
/home/coder/.local/bin/claude
```

Check what the wrapper actually does:

```bash
cat ~/.local/bin/boundary-wrappers/claude
```

Stronger models (e.g. Opus 4.5) reliably **refuse** obvious firewall-demo prompts — they pattern-match exfil and just won't do it. That's correct model behavior, but it means the firewall never actually gets exercised. Haiku 4.5 is weaker on safety deliberation and happily runs what it's asked, letting boundary do its job — which is why the `claude` wrapper pins Haiku by default.

> **Model note (RH Summit 2026 re-install):** models were remapped to those provisioned in this deployment's AI Gateway. Haiku 4.5 remains a good weak-safety model for the `claude` path. There is currently **no weak OpenAI-compatible model routable through the AI Gateway**, so `codex` defaults to `us.openai.gpt-5.6-luna` (a strong model that may refuse the demo prompts). Run the firewall demo primarily through `claude`.

## Allowlist

`boundary.config.yaml.tftpl` (next to `main.tf`) defines ~180 allowed hosts, based on [Claude Code's official default list](https://code.claude.com/docs/en/claude-code-on-the-web#default-allowed-domains) plus deployment-specific additions:

- **This Coder deployment** — rendered from the workspace's access URL at plan time
- **Internal services** — `gitlab.zambruhni.com` so agents can hit internal repos
- **AI providers** — Anthropic, OpenAI, Google
- **Version control** — GitHub, GitLab.com, Bitbucket
- **Container registries** — Docker Hub, GCR, GHCR, MCR
- **Package managers** — npm, PyPI, RubyGems, Cargo, Go, Maven, NuGet, pub.dev, hex.pm, CPAN, CocoaPods, Hackage, Swift
- **Linux distros, dev tools, cloud platforms** — comprehensive coverage
- **Claude Code telemetry (Datadog POST)** — permitted

Deliberately *not* allowlisted (these are what power the demos):

- **npm / yarn registries** — `registry.npmjs.org`, `npmjs.com`, etc. Any `npm install` fails fast; that's the Part 1 demo. If you fork this template for real dev work, add them back.
- `*.cool-project.io` — fake "cool-project" CDNs / telemetry / mirrors driving the Part 2 demo
- `webhook.site` — classic exfiltration destination
- `*.example.com` — generic untrusted placeholder

### Extending the allowlist

One-off, in the current shell:

```bash
boundary --allow "domain=example.com" -- my-command
```

Permanent: edit `boundary.config.yaml.tftpl` and push a new template version. The file is rendered through Terraform's `templatefile()` at plan time — `${coder_host}` at the top is substituted with the deployment's access URL; everything else is literal YAML.

## Operator smoke tests

Two pre-staged scripts at `~/demo/` prove boundary is in the network path. Run either in the workspace terminal before the audience joins:

```bash
# Expected: exit != 0, connection error, DENY on Grafana
~/demo/exfil-test.sh

# Expected: exit != 0, pip resolver error
~/demo/unknown-registry-test.sh
```

These are OPERATOR tools, not agent-facing. Keep the agent working out of `~/cool-project/`; exploring `~/demo/` would give the game away.

## Known fragility: wrapper PATH ordering

The wrappers only work because `~/.local/bin/boundary-wrappers` is first in `PATH`. The template writes an `export PATH=...` line to `.profile`, `.bashrc`, `.zshrc`, and `.zprofile`, and the dotfiles module's `post_clone_script` re-appends the export after user dotfiles are cloned. That survives most dotfile frameworks (oh-my-zsh / prezto / starship) that replace rc files wholesale.

If `which claude` in a workspace returns `/home/coder/.local/bin/claude` instead of the wrapper path, a later-sourced rc file reset `PATH` without including the wrappers dir. Fix:

```bash
# one-shot, current shell only:
export PATH="$HOME/.local/bin/boundary-wrappers:$PATH"

# persistent: append to whichever rc file ran last
echo 'export PATH="$HOME/.local/bin/boundary-wrappers:$PATH"' >> ~/.zshrc
```

The structurally robust alternative — shadowing the real binary at `~/.local/bin/claude` — would break Claude Code's in-place auto-updater, so the wrapper-dir approach is what we use.

## Prerequisites

> [!NOTE]
> This template runs the pod under the **`coder-firewall-runner`**
> ServiceAccount, bound to the custom **`coder-firewall-scc`** SCC
> (`manifests/cluster-config/coder-firewall-scc.yaml`). That SCC mirrors
> restricted-v2 but additionally allows the `NET_ADMIN` + `SYS_ADMIN`
> capabilities (requested in the pod `security_context`). These were required
> by boundary's original nsjail backend; the **landjail** backend used here
> doesn't strictly need them, but the SCC + caps are kept so the template also
> works if nsjail is ever re-enabled. UID / SELinux / seccomp are still
> injected by the SCC at admission time.

- OpenShift / Kubernetes cluster reachable from Coder
- The `coder-firewall-scc` SCC applied and bound to `coder-firewall-runner` in the workspace namespace
- Coder deployment (2.37.x) with the **AI Gateway** enabled and the `bedrock` + `openai-compat` providers configured (see `ai-providers/`)

## Architecture

- **Image:** `${var.image_registry}/ubi9-node-workspace:latest` (OpenShift internal registry, mirrored from GHCR)
- **Pod:** single container under the `coder-firewall-runner` SA, with `NET_ADMIN` + `SYS_ADMIN` caps; UID injected by `coder-firewall-scc`
- **Storage:** ReadWriteOnce PVC at `/home/coder`
- **Anti-affinity:** soft preference to spread workspaces across nodes
- **Dotfiles default:** `https://github.com/ausbru87/dotfiles` (branch `demo`) — editable per-workspace
- **Auto-cloned repo:** `https://gitlab.zambruhni.com/lab/cool-project.git` — the demo SDK whose `CLAUDE.md` / `AGENTS.md` drive the demo flow; clear `git_repo` to skip

## Deploying

```bash
cd coder-templates/demo-ai-gov-firewall-ocp
coder templates push demo-ai-gov-firewall-ocp \
  --directory . \
  --variable namespace=coder-workspaces \
  --variable image_registry=image-registry.openshift-image-registry.svc:5000/coder-workspaces \
  --yes
```

Existing running workspaces don't auto-update — they stay on whatever version
they were created from until stopped and restarted.
