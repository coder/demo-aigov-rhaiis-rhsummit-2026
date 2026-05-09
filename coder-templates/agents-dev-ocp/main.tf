# =============================================================================
# Agents Dev — Kubernetes Development Template for Coder Agents
# =============================================================================
# Well-tooled development workspace designed for the Coder Agents feature
# (CODER_EXPERIMENTS=agents). The LLM runs server-side on the control plane
# via `chatd` and connects to workspace agents remotely using tools like
# execute, read_file, and write_file.
#
# Because AI runs on the control plane, this template does NOT include:
#   - AI Bridge env vars or URLs
#   - Claude Code / Codex / Gemini CLI / Kiro CLI installations
#   - coder_ai_task or data.coder_task resources
#   - API key injection via coder_env
#   - Any LLM provider configuration
#
# Included tools:
#   Web IDEs:
#     - code-server (VS Code in the browser)
#   System packages (installed on startup):
#     Critical: git, curl, wget, ca-certificates, openssh-client,
#              jq, ripgrep, fd-find, build-essential, pkg-config,
#              python3, python3-pip, unzip, tar, gzip, procps, lsof,
#              sed, gawk
#     Nice-to-have: tree, shellcheck, diffutils, inotify-tools,
#                   netcat-openbsd, dnsutils
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

data "coder_parameter" "dotfiles_url" {
  name         = "dotfiles_url"
  display_name = "Dotfiles URL"
  description  = "Git repository URL for your dotfiles (optional)."
  type         = "string"
  default      = ""
  mutable      = false
  icon         = "/icon/dotfiles.svg"
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
# Agent — startup script installs common dev tools
# -----------------------------------------------------------------------------

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  # The startup script runs on every workspace start. It:
  #   1. Sets up PATH for npm global bin, ~/.local/bin
  #   2. Installs common development packages via apt
  startup_script = <<-EOT
    #!/bin/bash
    touch ~/.bashrc

    # Set up PATH (npm global bin + ~/.local/bin)
    NPM_BIN="$(npm config get prefix)/bin"
    export PATH="$HOME/.local/bin:$NPM_BIN:$PATH"

    # Persist PATH additions in .profile (sourced by login shells / Coder terminal)
    for P in "$HOME/.local/bin" "$NPM_BIN"; do
      grep -qF "$P" ~/.profile 2>/dev/null || echo "export PATH=\"$P:\$PATH\"" >> ~/.profile
    done

    # Workspace base image (UBI9 enterprise-node) already ships
    # git/curl/wget/jq/sudo/openssh-clients/python3.11/pip/gcc/make/
    # tar/unzip/vim plus Node 22 + corepack. The apt-get install
    # block from the source (Ubuntu) template is dropped — UBI9 uses
    # dnf, and these packages are pre-baked. Anything not in the
    # base goes through dnf+EPEL below; tolerant of "package not
    # available."
    if command -v dnf >/dev/null 2>&1; then
      echo "=== UBI9 nice-to-haves (EPEL) ==="
      sudo dnf install -y --nodocs \
        https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm 2>/dev/null || true
      sudo dnf install -y --nodocs ripgrep fd-find tree shellcheck inotify-tools nmap-ncat bind-utils lsof procps-ng 2>/dev/null || true
    fi

    echo "=== Workspace Ready ==="
  EOT

  env = {
    EDITOR = "code"
    VISUAL = "code"
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

# --- Utilities ---

# dotfiles — clone and apply user dotfiles on workspace start
module "dotfiles" {
  count        = data.coder_parameter.dotfiles_url.value != "" ? data.coder_workspace.me.start_count : 0
  source       = "registry.coder.com/coder/dotfiles/coder"
  version      = "1.0.23"
  agent_id     = coder_agent.main.id
  dotfiles_uri = data.coder_parameter.dotfiles_url.value
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
