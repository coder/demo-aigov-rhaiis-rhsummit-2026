# =============================================================================
# Demo: AI Gov (no firewall) — Kubernetes Development Template
# =============================================================================
# Baseline companion to `demo-ai-gov-firewall`. Identical toolchain, same
# pre-cloned demo repo, same pinned model defaults — the ONLY difference
# is that this template does NOT install Coder Agent Firewall (boundary).
# Agents here have unrestricted network access. Use this side of the
# pair to show what AI coding agents can reach when governance isn't
# in place, then run the same prompt in demo-ai-gov-firewall to show
# the contrast.
#
# Workspace access (three buttons in the Coder dashboard):
#     - VS Code Desktop (built-in display_app)
#     - code-server       (module — VS Code in the browser)
#     - Terminal          (built-in display_app — web terminal)
#
# Included CLIs (matches demo-ai-gov-firewall exactly — minus boundary):
#     - Claude Code (Anthropic, native install)
#     - Codex       (OpenAI, npm)
#
# AI access:
#   Both CLIs authenticate through Coder AI Bridge using the workspace
#   owner's session token — no external API keys needed.
#
# Key environment variables (set on the agent):
#   ANTHROPIC_BASE_URL / ANTHROPIC_API_BASE — AI Bridge Anthropic endpoint
#   OPENAI_BASE_URL                         — AI Bridge OpenAI endpoint
#   CLAUDE_API_KEY                          — session token (for Claude Code CLI)
#   OPENAI_API_KEY                          — session token (for Codex CLI)
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
  description  = "Repository to clone on workspace start. Defaults to the shared demo repo (cool-project) so the firewall vs no-firewall comparison runs on the same surface. Clear this field to skip cloning."
  type         = "string"
  default      = "https://gitlab.zambruhni.com/lab/cool-project.git"
  mutable      = false
  icon         = "/icon/git.svg"
}

# Dotfiles URL/branch at template root (instead of taking the module's
# built-in ones) so the workspace preset + prebuilds block can
# reference them by name — Coder's preset validator only sees
# template-root coder_parameter data sources. Passed into
# module.dotfiles as `dotfiles_uri` / `dotfiles_branch`, suppressing
# the module's own prompts.
data "coder_parameter" "dotfiles_uri" {
  name         = "dotfiles_uri"
  display_name = "Dotfiles URL"
  description  = "Git repository URL for your dotfiles. Defaults to the shared demo dotfiles. Clear this to skip the clone."
  type         = "string"
  default      = "https://gitlab.zambruhni.com/lab/dotfiles"
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

  # Claude Code settings.json — written to ~/.claude/settings.json
  # Controls environment variables, model selection, and onboarding state
  claude_settings = {
    env = {
      ANTHROPIC_BASE_URL  = local.ai_bridge_anthropic_url
      OPENAI_BASE_URL     = local.ai_bridge_openai_url
      GH_TOKEN            = data.coder_external_auth.github.access_token
      GH_USERNAME         = data.coder_workspace_owner.me.name
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
  #   2. Installs Claude Code (native) and Codex (npm) — pinned to the
  #      same versions as demo-ai-gov-firewall for parity
  #   3. Writes Claude Code config (settings.json + .claude.json)
  #   4. Writes Codex config (config.toml with AI Bridge provider)
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

    # Remove stale Yarn apt repo (expired GPG key causes apt-get update warnings)
    sudo rm -f /etc/apt/sources.list.d/yarn.list 2>/dev/null || true

    # Install Claude Code CLI — pinned to match demo-ai-gov-firewall.
    echo "Installing Claude Code CLI v2.1.116..."
    curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.116 || echo "Warning: Claude Code install failed"

    # Install Codex CLI — pinned to match demo-ai-gov-firewall.
    echo "Installing Codex CLI v0.122.0..."
    sudo npm install -g @openai/codex@0.122.0 || echo "Warning: Codex install failed"

    # Claude Code configuration
    echo "Configuring Claude Code..."
    mkdir -p ~/.claude
    cat > ~/.claude/settings.json << 'CLAUDESETTINGS'
    ${jsonencode(local.claude_settings)}
    CLAUDESETTINGS
    cat > ~/.claude.json << 'CLAUDECONFIG'
    ${jsonencode(local.claude_config)}
    CLAUDECONFIG

    # Codex configuration (AI Bridge)
    echo "Configuring Codex..."
    mkdir -p ~/.codex
    cat > ~/.codex/config.toml << 'CODEXEOF'
    sandbox_mode = "workspace-write"
    approval_policy = "never"
    preferred_auth_method = "apikey"
    profile = "aibridge"

    [sandbox_workspace_write]
    network_access = true

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

    # Install CLI wrappers that pin each agent to the SAME model + flags
    # used in demo-ai-gov-firewall. The only structural difference between
    # the two templates is that those wrappers prepend `boundary --`; here
    # they invoke the tool directly. Keeping the model + flags identical
    # means an A/B run of a prompt is actually comparing firewall vs
    # no-firewall and nothing else.
    #
    # claude: --dangerously-skip-permissions --model haiku
    # codex:  --dangerously-bypass-approvals-and-sandbox --model gpt-5.1-codex-mini
    echo "Installing demo wrappers..."
    WRAPPERS_DIR="$HOME/.local/bin/demo-wrappers"
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
      printf '#!/usr/bin/env bash\nexec %q %s "$@"\n' "$REAL_BIN" "$DEFAULT_ARGS" > "$WRAPPERS_DIR/$tool"
      chmod +x "$WRAPPERS_DIR/$tool"
      echo "  $tool → $REAL_BIN $DEFAULT_ARGS"
    done

    for RC in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zprofile"; do
      touch "$RC"
      grep -qF 'demo-wrappers' "$RC" || \
        echo 'export PATH="$HOME/.local/bin/demo-wrappers:$PATH"' >> "$RC"
    done

    echo "=== Workspace Ready ==="
  EOT

  # Environment variables available to all processes in the workspace.
  # These point AI tools at the AI Bridge proxy endpoints.
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

  display_apps {
    vscode                 = true
    vscode_insiders        = false
    web_terminal           = true
    ssh_helper             = false
    port_forwarding_helper = false
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
  # startup_script above appends the demo-wrappers PATH export to
  # .profile/.bashrc/.zshrc/.zprofile, but many dotfiles repos (oh-my-zsh,
  # prezto, etc.) REPLACE those files wholesale, wiping our export. This
  # hook re-appends it to whatever rc files are in place post-clone — so
  # `claude` and `codex` always resolve to the model-pinned wrappers
  # (matching the firewall variant's behavior) regardless of dotfiles.
  post_clone_script = <<-EOT
    #!/usr/bin/env bash
    set -e
    LINE='export PATH="$HOME/.local/bin/demo-wrappers:$PATH"'
    for RC in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zprofile"; do
      [ -f "$RC" ] || continue
      grep -qF 'demo-wrappers' "$RC" && continue
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
    container {
      name              = "dev"
      image             = "${var.image_registry}/enterprise-node:latest"
      image_pull_policy = "Always"
      command           = ["sh", "-c", coder_agent.main.init_script]

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
