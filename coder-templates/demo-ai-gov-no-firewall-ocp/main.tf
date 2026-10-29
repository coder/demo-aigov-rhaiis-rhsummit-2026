# =============================================================================
# Demo: AI Gov (no firewall) — Kubernetes Development Template (OpenShift)
# =============================================================================
# Baseline companion to `demo-ai-gov-firewall`. Identical toolchain, same
# pre-cloned demo repo, same pinned model defaults — the ONLY difference is
# that this template does NOT install Coder Agent Firewall (boundary).
# Agents here have unrestricted network access. Run the same prompt here and
# in demo-ai-gov-firewall to show the contrast.
#
# Claude Code + Codex are installed and configured by their official Coder
# Registry modules (coder/claude-code, coder-labs/codex) and route through the
# Coder AI Gateway using the workspace owner's session token:
#     Claude Code -> provider `bedrock`        (model: Haiku 4.5)
#     Codex       -> provider `openai-compat`  (model: GPT-5.6 Luna)
# Models match demo-ai-gov-firewall so an A/B run compares firewall vs
# no-firewall and nothing else. The modules pin the models (claude-code `model`
# input / codex `base_config_toml`), so no CLI wrappers are needed here.
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

# Anthropic model Claude Code requests through the AI Gateway (bedrock
# provider). Haiku 4.5 by default — matches demo-ai-gov-firewall.
variable "anthropic_model" {
  type        = string
  description = "Model id Claude Code requests through the Coder AI Gateway (bedrock provider)."
  default     = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
}

# OpenAI-compatible model Codex requests through the AI Gateway (openai-compat
# provider). GPT-5.6 Luna by default — matches demo-ai-gov-firewall.
variable "openai_model" {
  type        = string
  description = "Model id Codex requests through the Coder AI Gateway (openai-compat provider)."
  default     = "us.openai.gpt-5.6-luna"
}

provider "kubernetes" {
  config_path = var.use_kubeconfig ? "~/.kube/config" : null
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# GitLab external_auth (optional). GitHub external_auth was removed —
# GitLab is the only SCM integration for now.
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
  description  = "Repository to clone on workspace start. Defaults to the shared demo repo (cool-project) so the firewall vs no-firewall comparison runs on the same surface. Clear this field to skip cloning."
  type         = "string"
  default      = "https://gitlab.zambruhni.com/lab/cool-project.git"
  mutable      = false
  icon         = "/icon/git.svg"
}

# Dotfiles URL/branch at template root (instead of the module's built-in ones)
# so the workspace preset + prebuilds block can reference them by name.
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
# Locals — AI Gateway endpoints + Codex config
# -----------------------------------------------------------------------------

locals {
  # AI Gateway (Coder 2.37.x) routes by PROVIDER NAME under
  # /api/v2/ai-gateway/<provider>, authenticated with the Coder session
  # token. Providers: `bedrock` (Anthropic -> Claude Code) and
  # `openai-compat` (OpenAI Responses -> Codex). Canonical prefix is
  # /api/v2/ai-gateway (matches the proven partner reference templates).
  ai_gateway_anthropic_url = "${data.coder_workspace.me.access_url}/api/v2/ai-gateway/bedrock"
  ai_gateway_openai_v1_url = "${data.coder_workspace.me.access_url}/api/v2/ai-gateway/openai-compat/v1"

  # Codex config.toml — written verbatim by the coder-labs/codex module.
  #   * web_search = "disabled": Bedrock's OpenAI endpoint rejects Codex's
  #     default hosted web_search tool ("web search is not supported"),
  #     closing the stream mid-turn. Disabling it lets turns complete.
  #   * sandbox_mode = "danger-full-access": the pod is already the sandbox
  #     and lacks bubblewrap.
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
# Agent — startup locks Claude Code settings (CLIs installed by modules)
# -----------------------------------------------------------------------------

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  startup_script = <<-EOT
    #!/bin/bash
    touch ~/.bashrc

    # PATH for npm global bin + ~/.local/bin (where the modules install the CLIs)
    NPM_BIN="$(npm config get prefix)/bin"
    export PATH="$HOME/.local/bin:$NPM_BIN:$PATH"
    for P in "$HOME/.local/bin" "$NPM_BIN"; do
      grep -qF "$P" ~/.profile 2>/dev/null || echo "export PATH=\"$P:\$PATH\"" >> ~/.profile
    done

    # Claude Code user settings: bypass permission prompts and LOCK the model
    # picker to the gateway's provisioned Anthropic models (selecting an
    # unconfigured model makes the gateway reject the request). The
    # coder/claude-code module writes install state to ~/.claude.json (a
    # different file), so this is safe.
    mkdir -p ~/.claude
    cat > ~/.claude/settings.json << 'CLAUDESETTINGS'
    {
      "permissions": { "defaultMode": "bypassPermissions" },
      "skipDangerousModePermissionPrompt": true,
      "hasCompletedOnboarding": true,
      "hasAcknowledgedCostThreshold": true,
      "availableModels": [
        "global.anthropic.claude-haiku-4-5-20251001-v1:0",
        "global.anthropic.claude-opus-4-5-20251101-v1:0"
      ]
    }
    CLAUDESETTINGS

    echo "=== Workspace Ready ==="
  EOT

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

    # Coder v2.33 flipped devcontainer detection to opt-on. With no docker
    # socket in the pod, the agent hangs 4-8s per dashboard poll on `docker ps`.
    # Opt back out since this template has no devcontainer flow.
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
# AI Gateway auth — workspace owner's session token as the API key.
# ANTHROPIC_MODEL is set by the coder/claude-code module (var.anthropic_model).
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

# Claude Code — native install; model -> ANTHROPIC_MODEL. Gateway endpoint +
# key come from the coder_env above.
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
    # Detached + backgrounded so this NEVER blocks workspace "ready"/startup.
    # It waits for the claude-code module to finish writing ~/.claude.json
    # (hasCompletedOnboarding=true), then merges the current ANTHROPIC_API_KEY
    # suffix (last 20 chars) into customApiKeyResponses.approved so Claude Code
    # does not prompt. Output is redirected to a log file (NOT the agent's
    # stdout pipe) so the orphaned background job can't hold the script open.
    (
      set -u
      CFG="$HOME/.claude.json"
      for _ in $(seq 1 60); do
        [ -f "$CFG" ] && jq -e '.hasCompletedOnboarding == true' "$CFG" >/dev/null 2>&1 && break
        sleep 2
      done
      [ -f "$CFG" ] || echo '{}' > "$CFG"
      KEY="$${ANTHROPIC_API_KEY:-}"
      [ -n "$KEY" ] || exit 0
      SUFFIX=$(printf %s "$KEY" | tail -c 20)
      tmp=$(mktemp)
      jq --arg k "$SUFFIX" '.customApiKeyResponses = (.customApiKeyResponses // {"approved":[],"rejected":[]}) | .customApiKeyResponses.approved = (((.customApiKeyResponses.approved // []) + [$k]) | unique) | .customApiKeyResponses.rejected = ((.customApiKeyResponses.rejected // []) - [$k])' "$CFG" > "$tmp" 2>/dev/null \
        && mv "$tmp" "$CFG" && echo "Pre-approved ANTHROPIC_API_KEY." \
        || rm -f "$tmp"
    ) >/tmp/claude-approve-key.log 2>&1 &
    disown 2>/dev/null || true
    exit 0
  EOT
}

# Codex — pinned standalone binary + config.toml from base_config_toml.
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

# code-server — VS Code in the browser (VS Code Desktop + Terminal come from
# coder_agent.display_apps above).
module "code-server" {
  count     = data.coder_workspace.me.start_count
  source    = "registry.coder.com/coder/code-server/coder"
  version   = "1.3.1"
  agent_id  = coder_agent.main.id
  folder    = "/home/coder"
  subdomain = true

  # Run the code-server binary pre-baked into the workspace image
  # (ubi9-node-workspace: /usr/lib/code-server) instead of downloading it from
  # code-server.dev on every start. offline=true => the module never fetches
  # from the internet — air-gapped posture + no flaky-download startup failures.
  install_prefix = "/usr/lib/code-server"
  offline        = true

  # Disable GitHub Copilot / Copilot Chat in code-server so it does not surface
  # in the UI and conflict with the demo's own AI agents. In this code-server
  # build the chat panel is baked into VS Code CORE (product.json
  # defaultChatAgent -> GitHub.copilot), NOT an extension, so the real
  # kill-switch is chat.disableAIFeatures (application scope => USER settings).
  # The workspace image additionally strips defaultChatAgent from product.json,
  # and extensions.allowed blocks the Copilot extensions from being enabled if
  # side-loaded.
  settings = {
    "chat.disableAIFeatures" = true
  }
  machine-settings = {
    "chat.disableAIFeatures" = true
    "extensions.allowed" = {
      "*"                   = true
      "github.copilot"      = false
      "github.copilot-chat" = false
    }
  }
  order = 1
}

# dotfiles — clone and apply user dotfiles on workspace start
module "dotfiles" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/dotfiles/coder"
  version  = "1.4.1"
  agent_id = coder_agent.main.id

  dotfiles_uri    = data.coder_parameter.dotfiles_uri.value
  dotfiles_branch = data.coder_parameter.dotfiles_branch.value
}

# git-clone — clone the demo repo into /home/coder on workspace start
module "git-clone" {
  count    = data.coder_parameter.git_repo.value != "" ? data.coder_workspace.me.start_count : 0
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "1.2.3"
  agent_id = coder_agent.main.id
  url      = data.coder_parameter.git_repo.value
  base_dir = "/home/coder"
}

# -----------------------------------------------------------------------------
# AI CLI launchers (coder_app) — the modules install the binaries; these give
# clickable terminal launchers. No firewall: they run the CLIs directly.
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

  lifecycle {
    ignore_changes = all
  }
}
