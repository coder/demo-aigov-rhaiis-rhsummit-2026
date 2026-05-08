# =============================================================================
# AI Dev — Kubernetes Development Template
# =============================================================================
# AI-focused dev environment on Kubernetes.
#
# Included tools:
#   Web IDEs:
#     - code-server (VS Code in the browser)
#     - mux (terminal multiplexer with AI provider UI)
#   Desktop IDEs:
#     - Kiro IDE (AWS/Anthropic coding agent)
#     - Cursor IDE (AI-powered VS Code fork)
#   Terminal CLIs:
#     - Claude Code (Anthropic, native install)
#     - Codex (OpenAI, npm)
#     - Gemini CLI (Google, npm)
#     - Kiro CLI (AWS, curl install)
#
# AI access:
#   Claude Code, Codex, and Gemini CLI authenticate through Coder's AI
#   Bridge, which proxies requests using the workspace owner's session
#   token. Kiro authenticates independently (AWS Builder ID, etc.).
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
  description  = "Repository to clone on workspace start (optional)."
  type         = "string"
  default      = ""
  mutable      = false
  icon         = "/icon/git.svg"
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

  # Mux provider configuration — written to ~/.mux/providers.jsonc
  # Configures the Anthropic provider with AI Bridge base URL and models
  mux_provider_settings = {
    "anthropic" = {
      "serviceTier" = "default"
      "models" = [
        "claude-haiku-4-5-20251001",
        "claude-opus-4-6-20250610"
      ]
      "baseUrl" = local.ai_bridge_anthropic_url
      "apiKey"  = data.coder_workspace_owner.me.session_token
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
  #   2. Installs Claude Code (native), Codex (npm), Gemini CLI (npm), Kiro CLI (curl)
  #   3. Writes Claude Code config (settings.json + .claude.json)
  #   4. Writes Codex config (config.toml with AI Bridge provider)
  #   5. Writes Mux provider config (providers.jsonc)
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

    # Install Claude Code CLI (native installer — auto-updates, no Node.js dependency)
    echo "Installing Claude Code CLI..."
    curl -fsSL https://claude.ai/install.sh | bash || true

    # Install Codex CLI
    echo "Installing Codex CLI..."
    sudo npm install -g @openai/codex@latest || true

    # Install Gemini CLI
    echo "Installing Gemini CLI..."
    sudo npm install -g @google/gemini-cli@latest || true

    # Install Kiro CLI
    echo "Installing Kiro CLI..."
    curl -fsSL https://cli.kiro.dev/install | bash || true

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

    # Mux AI provider configuration
    echo "Configuring Mux..."
    mkdir -p ~/.mux
    cat > ~/.mux/providers.jsonc << 'MUXEOF'
    ${jsonencode(local.mux_provider_settings)}
    MUXEOF

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

# --- Web IDEs ---

# code-server — VS Code in the browser, accessible via subdomain
module "code-server" {
  count     = data.coder_workspace.me.start_count
  source    = "registry.coder.com/coder/code-server/coder"
  version   = "1.3.1"
  agent_id  = coder_agent.main.id
  folder    = "/home/coder"
  subdomain = true
  group     = "Web IDEs"
  order     = 1
}

# --- Desktop IDEs ---

# kiro — Kiro Desktop IDE connection (external app, kiro:// protocol)
module "kiro" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/kiro/coder"
  version  = "1.0.0"
  agent_id = coder_agent.main.id
  folder   = "/home/coder"
  group    = "Desktop IDEs"
  order    = 3
}

# cursor — Cursor Desktop IDE connection (external app)
module "cursor" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/cursor/coder"
  version  = "1.4.1"
  agent_id = coder_agent.main.id
  folder   = "/home/coder"
  group    = "Desktop IDEs"
  order    = 4
}

# mux — terminal multiplexer with built-in AI provider switching UI
module "mux" {
  count     = data.coder_workspace.me.start_count
  source    = "registry.coder.com/coder/mux/coder"
  version   = "1.4.3"
  agent_id  = coder_agent.main.id
  subdomain = true
  group     = "Web IDEs"
  order     = 2
}

# dotfiles — clone and apply user dotfiles on workspace start
module "dotfiles" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/dotfiles/coder"
  version  = "1.4.1"
  agent_id = coder_agent.main.id

  # Surface both "Dotfiles URL" and "Dotfiles Branch" in the workspace
  # create form. Defaults pre-filled but fully editable per-workspace;
  # clear the URL field to skip cloning (the module's run.sh guards
  # against an empty URI).
  default_dotfiles_uri    = "https://gitlab.zambruhni.com/lab/dotfiles"
  default_dotfiles_branch = "main"
}

# git-clone — clone a repo into /home/coder on workspace start
module "git-clone" {
  count    = data.coder_parameter.git_repo.value != "" ? data.coder_workspace.me.start_count : 0
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "1.0.22"
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
      command           = ["/usr/local/bin/uid_entrypoint", "sh", "-c", coder_agent.main.init_script]

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
}
