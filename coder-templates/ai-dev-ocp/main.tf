# =============================================================================
# AI Dev — Kubernetes Development Template (OpenShift)
# =============================================================================
# AI-focused dev environment on OpenShift/Kubernetes.
#
# Included tools:
#   Web IDEs:        code-server (VS Code in the browser)
#   Desktop IDEs:    Kiro IDE, Cursor IDE
#   Terminal CLIs:   Claude Code + Codex (Coder Registry modules),
#                    Gemini CLI + Kiro CLI (installed in the agent startup)
#
# AI access — Coder AI Gateway (Coder 2.37.x):
#   Claude Code and Codex are installed and configured by their official
#   Coder Registry modules (coder/claude-code, coder-labs/codex). Both route
#   through the Coder AI Gateway using the workspace owner's session token:
#     Claude Code -> provider `bedrock`        (Anthropic Messages API)
#     Codex       -> provider `openai-compat`  (OpenAI Responses API)
#   The gateway routes by PROVIDER NAME under /api/v2/ai-gateway/<provider>.
#   Auth is wired via agent-wide coder_env (ANTHROPIC_* / OPENAI_*), matching
#   the proven partner reference templates (greg-the-coder/partner-ai-dlc-gitops).
#   Kiro authenticates independently (AWS Builder ID, etc.).
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
  description = "Container registry that hosts the workspace base images. Defaults to the in-cluster OpenShift internal registry (images mirrored from GHCR via coder-templates/images/mirror-to-internal-registry.sh for a self-contained / air-gapped deploy; override at push time if you fork)."
  type        = string
  default     = "image-registry.openshift-image-registry.svc:5000/coder-workspaces"
}

# Anthropic model Claude Code requests through the AI Gateway. Must be a model
# registered on the gateway's `bedrock` provider (see ai-providers/). Defaults
# to the provisioned Claude Opus 4.5 Bedrock inference profile.
variable "anthropic_model" {
  type        = string
  description = "Model id Claude Code requests through the Coder AI Gateway (bedrock provider)."
  default     = "global.anthropic.claude-opus-4-5-20251101-v1:0"
}

# OpenAI-compatible model Codex requests through the AI Gateway (openai-compat
# provider). Defaults to the provisioned GPT-5.6 Sol cross-region profile.
variable "openai_model" {
  type        = string
  description = "Model id Codex requests through the Coder AI Gateway (openai-compat provider)."
  default     = "us.openai.gpt-5.6-sol"
}


provider "kubernetes" {
  config_path = var.use_kubeconfig ? "~/.kube/config" : null
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# GitLab external_auth (optional) — workspace boots whether or not the
# user has authenticated. GitHub external_auth was removed; GitLab is the
# only SCM integration for now.
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
  description  = "Repository to clone on workspace start (optional)."
  type         = "string"
  default      = ""
  mutable      = false
  icon         = "/icon/git.svg"
}

# -----------------------------------------------------------------------------
# Locals — AI Gateway endpoints + Codex config
# -----------------------------------------------------------------------------

locals {
  # AI Gateway (Coder 2.37.x) routes by PROVIDER NAME under
  # /api/v2/ai-gateway/<provider>, authenticated with the Coder session
  # token. Our configured providers are `bedrock` (Anthropic Messages API
  # -> Claude Code) and `openai-compat` (OpenAI Responses API -> Codex).
  # The provider *type* aliases /anthropic and /openai are NOT valid routes
  # (404 "route not supported"). Canonical prefix is /api/v2/ai-gateway
  # (matches the proven partner reference templates).
  ai_gateway_anthropic_url = "${data.coder_workspace.me.access_url}/api/v2/ai-gateway/bedrock"
  ai_gateway_openai_v1_url = "${data.coder_workspace.me.access_url}/api/v2/ai-gateway/openai-compat/v1"

  # Codex config.toml — written verbatim by the coder-labs/codex module
  # (base_config_toml). Routes Codex through the AI Gateway openai-compat
  # provider using OPENAI_API_KEY (the Coder session token, set below).
  #   * web_search = "disabled": Codex attaches a hosted web_search tool by
  #     default, which Amazon Bedrock's OpenAI endpoint rejects ("web search
  #     is not supported for this request"), closing the stream mid-turn.
  #     Disabling it lets turns complete. (Verified against this gateway.)
  #   * sandbox_mode = "danger-full-access": the workspace pod is already the
  #     sandbox and lacks bubblewrap, which Codex's workspace-write OS sandbox
  #     requires.
  #   * wire_api = "responses": current Codex dropped "chat".
  codex_base_config = <<-TOML
    model_provider = "openai-compat"
    model = "${var.openai_model}"
    model_reasoning_effort = "medium"
    web_search = "disabled"
    sandbox_mode = "danger-full-access"
    approval_policy = "never"

    [features]
    daemon_auto_start = false

    [model_providers.openai-compat]
    name = "Coder AI Gateway (Bedrock)"
    base_url = "${local.ai_gateway_openai_v1_url}"
    env_key = "OPENAI_API_KEY"
    wire_api = "responses"

    [projects."/home/coder"]
    trust_level = "trusted"
  TOML
}

# -----------------------------------------------------------------------------
# Agent — startup installs Gemini + Kiro CLIs and locks Claude Code settings
# -----------------------------------------------------------------------------

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  # Claude Code and Codex are installed by their Coder Registry modules
  # below. This script installs the remaining CLIs (Gemini, Kiro) and writes
  # Claude Code's user settings (permission bypass + model lock).
  startup_script = <<-EOT
    #!/bin/bash
    touch ~/.bashrc

    # Set up PATH for this script (npm global bin + ~/.local/bin).
    NPM_BIN="$(npm config get prefix)/bin"
    export PATH="$HOME/.local/bin:$NPM_BIN:$PATH"

    # Persist PATH additions in .profile (sourced by login shells / Coder terminal)
    for P in "$HOME/.local/bin" "$NPM_BIN"; do
      grep -qF "$P" ~/.profile 2>/dev/null || echo "export PATH=\"$P:\$PATH\"" >> ~/.profile
    done

    # Remove stale Yarn apt repo (expired GPG key causes apt-get update warnings)
    sudo rm -f /etc/apt/sources.list.d/yarn.list 2>/dev/null || true

    # Point npm globals at the user's HOME so `npm install -g` needs no sudo.
    # (restricted-v2 drops CAP_SETUID, so sudo can't elevate.)
    npm config set prefix "$HOME/.local" >/dev/null
    export PATH="$HOME/.local/bin:$PATH"

    # Install Gemini CLI (no sudo — user-prefixed npm above)
    echo "Installing Gemini CLI..."
    npm install --global --no-fund --no-audit @google/gemini-cli@latest || true

    # Install Kiro CLI. Upstream installer reads /dev/tty for a "replace
    # existing?" prompt, which fails inside the Coder agent's stdio
    # environment. Skip if already installed; otherwise pre-feed `y`.
    echo "Installing Kiro CLI..."
    if command -v kiro >/dev/null 2>&1; then
      echo "  (already installed; skipping)"
    else
      yes y 2>/dev/null | bash -c "$(curl -fsSL https://cli.kiro.dev/install)" || true
    fi

    # Claude Code user settings: bypass permission prompts (equivalent to
    # --dangerously-skip-permissions) and LOCK the model picker to the
    # gateway's provisioned Anthropic models. Selecting an unconfigured model
    # makes the AI Gateway reject the request and breaks the session. Written
    # as ~/.claude/settings.json (the coder/claude-code module writes install
    # state to ~/.claude.json — a different file — so this is safe).
    mkdir -p ~/.claude
    cat > ~/.claude/settings.json << 'CLAUDESETTINGS'
    {
      "permissions": { "defaultMode": "bypassPermissions" },
      "skipDangerousModePermissionPrompt": true,
      "hasCompletedOnboarding": true,
      "hasAcknowledgedCostThreshold": true,
      "availableModels": [
        "global.anthropic.claude-opus-4-5-20251101-v1:0",
        "global.anthropic.claude-haiku-4-5-20251001-v1:0"
      ]
    }
    CLAUDESETTINGS

    echo "=== Workspace Ready ==="
  EOT

  # Workspace-wide environment: editor + git identity. AI Gateway auth
  # (ANTHROPIC_* / OPENAI_*) is set via coder_env below.
  env = {
    EDITOR              = "code"
    VISUAL              = "code"
    GITLAB_TOKEN        = data.coder_external_auth.gitlab.access_token
    GITLAB_USER         = data.coder_workspace_owner.me.name
    GITLAB_HOST         = "gitlab.rhsummit.coderdemo.io"
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
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
# AI Gateway auth — workspace owner's Coder session token as the API key.
# The gateway validates the token and proxies requests to the configured
# providers (bedrock / openai-compat). ANTHROPIC_MODEL is set by the
# coder/claude-code module (var.anthropic_model).
# -----------------------------------------------------------------------------

resource "coder_env" "anthropic_base_url" {
  agent_id = coder_agent.main.id
  name     = "ANTHROPIC_BASE_URL"
  value    = local.ai_gateway_anthropic_url
}

resource "coder_env" "anthropic_api_key" {
  agent_id = coder_agent.main.id
  name     = "ANTHROPIC_API_KEY"
  value    = data.coder_workspace_owner.me.session_token
}

resource "coder_env" "openai_base_url" {
  agent_id = coder_agent.main.id
  name     = "OPENAI_BASE_URL"
  value    = local.ai_gateway_openai_v1_url
}

resource "coder_env" "openai_api_key" {
  agent_id = coder_agent.main.id
  name     = "OPENAI_API_KEY"
  value    = data.coder_workspace_owner.me.session_token
}

# -----------------------------------------------------------------------------
# Coder Registry Modules
# -----------------------------------------------------------------------------

# --- AI CLIs (official modules; route through the AI Gateway) ---

# Claude Code — installs the CLI (native installer) + a clickable launcher is
# provided by coder_app.claude_code below. model -> ANTHROPIC_MODEL; the
# gateway endpoint + key come from the coder_env above (we deliberately do NOT
# use the module's enable_ai_gateway, whose generic /anthropic route and
# ANTHROPIC_AUTH_TOKEN don't match our provider-named bedrock route).
module "claude-code" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/claude-code/coder"
  version  = "5.4.0"
  agent_id = coder_agent.main.id
  workdir  = "/home/coder"
  model    = var.anthropic_model
}

# Pre-approve the ANTHROPIC_API_KEY so Claude Code never shows its
# "Detected a custom API key ... Do you want to use this API key?" prompt on
# first use. Claude Code matches on the LAST 20 CHARACTERS it stores in
# ~/.claude.json under customApiKeyResponses.approved. Our key is the Coder
# session token, which rotates every workspace start, so this runs on_start.
# Modeled on the proven partner reference
# (greg-the-coder/partner-ai-dlc-gitops awshp-k8s-with-claude-code). The
# coder/claude-code module writes ~/.claude.json during install, so we wait
# for it to settle (hasCompletedOnboarding=true) before merging our entry.
resource "coder_script" "claude_approve_key" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  display_name = "Claude Code: pre-approve API key"
  icon         = "/icon/claude.svg"
  run_on_start = true
  script       = <<-EOT
    #!/usr/bin/env bash
    set -u
    CFG="$HOME/.claude.json"

    # Wait up to ~120s for the claude-code module install to finish writing
    # ~/.claude.json (hasCompletedOnboarding=true lands near the end of
    # install) so our edit is not clobbered.
    for _ in $(seq 1 60); do
      if [ -f "$CFG" ] && jq -e '.hasCompletedOnboarding == true' "$CFG" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    sleep 5
    [ -f "$CFG" ] || echo '{}' > "$CFG"

    KEY="$${ANTHROPIC_API_KEY:-}"
    if [ -n "$KEY" ]; then
      SUFFIX=$(printf %s "$KEY" | tail -c 20)
      tmp=$(mktemp)
      if jq --arg k "$SUFFIX" '
            .customApiKeyResponses = (.customApiKeyResponses // {"approved": [], "rejected": []})
            | .customApiKeyResponses.approved = (((.customApiKeyResponses.approved // []) + [$k]) | unique)
            | .customApiKeyResponses.rejected = ((.customApiKeyResponses.rejected // []) - [$k])
          ' "$CFG" > "$tmp" 2>/dev/null && mv "$tmp" "$CFG"; then
        echo "Pre-approved ANTHROPIC_API_KEY in $CFG (Claude Code will not prompt)."
      else
        rm -f "$tmp"; echo "Warning: could not pre-approve ANTHROPIC_API_KEY."
      fi
    fi
    exit 0
  EOT
}

# Codex — installs the pinned CLI (standalone binary) + writes config.toml
# from base_config_toml. 0.159.2 is the partner-reference-verified version.
module "codex" {
  count            = data.coder_workspace.me.start_count
  source           = "registry.coder.com/coder-labs/codex/coder"
  version          = "5.3.2"
  agent_id         = coder_agent.main.id
  workdir          = "/home/coder"
  install_codex    = true
  codex_version    = "0.159.2"
  base_config_toml = local.codex_base_config
}

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

# dotfiles — clone and apply user dotfiles on workspace start
module "dotfiles" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/dotfiles/coder"
  version  = "1.4.1"
  agent_id = coder_agent.main.id

  default_dotfiles_uri    = "https://github.com/ausbru87/dotfiles"
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
# AI CLI launchers (coder_app) — the modules install the binaries; these give
# a clickable terminal launcher in the workspace dashboard.
# -----------------------------------------------------------------------------

resource "coder_app" "claude_code" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "claude-code"
  display_name = "Claude Code"
  icon         = "/icon/claude.svg"
  group        = "AI Tools"
  order        = 5
  open_in      = "slim-window"
  command      = <<-EOT
    cd "$HOME"
    claude --dangerously-skip-permissions
  EOT
}

resource "coder_app" "codex" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "codex"
  display_name = "Codex"
  icon         = "/icon/openai.svg"
  group        = "AI Tools"
  order        = 6
  open_in      = "slim-window"
  command      = <<-EOT
    cd "$HOME"
    codex --no-daemon
  EOT
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
      image             = "${var.image_registry}/ubi9-node-workspace:latest"
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
