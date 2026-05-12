# =============================================================================
# Artemis Sim Dev — Kubernetes Development Template (no AI)
# =============================================================================
# OCP-native workspace for a "simulator engineer" persona working on the
# Artemis-2 simulator: a C++ backend (digital sim / runtime) and a
# Node/TypeScript frontend (3D visualization, telemetry dashboards).
#
# Design intent — deliberately NO AI tooling:
#   - No Claude Code, Codex, Gemini, or Kiro CLI
#   - No Kiro / Cursor desktop IDE modules
#   - No AI Bridge env vars (ANTHROPIC_BASE_URL, OPENAI_BASE_URL, etc.)
#   - No CLAUDE_API_KEY / OPENAI_API_KEY coder_env resources
#
# This is the "traditional SWE" half of the demo narrative — the contrast
# template to ai-dev-ocp and agents-dev-ocp. The simulator engineers
# review code, run cmake/clang/gdb, and iterate on TypeScript frontends
# the way teams did before in-IDE coding agents shipped.
#
# Included tools:
#   Web IDE:
#     - code-server (VS Code in the browser)
#   Registry modules:
#     - dotfiles (per-user dotfiles, optional)
#     - git-clone (clones the assigned Artemis-2 repo from GitLab)
#
# Base image:
#   ${var.image_registry}/ubi9-node-workspace:latest — the same UBI9 image
#   used by ai-dev-ocp, layered to include cmake / clang / gdb for C++
#   development (image build handled separately in coder-templates/images/).
#
# Repo cloning:
#   The `git_repo` parameter defaults to the Artemis-2 sim monorepo on
#   the self-hosted GitLab. The bridge service (sprint-ticket → workspace
#   automation) overrides this default per-issue via `rich_parameter_values`
#   when it creates a workspace for an assigned ticket.
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

# Self-hosted GitLab is the only SCM here — Artemis-2 lives on
# gitlab.rhsummit.coderdemo.io. The token is forwarded to the agent so
# git-clone can authenticate against private repos.
data "coder_external_auth" "gitlab" {
  id       = "gitlab"
  optional = true
}

# -----------------------------------------------------------------------------
# Parameters — workspace sizing and assigned repo
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


# git_repo is intentionally `mutable = false` — the workspace is bound to
# its assigned ticket's repo for the duration of its life. The bridge
# service overrides this default per-issue via `rich_parameter_values`
# when a sprint ticket is assigned to a simulator engineer; UI-driven
# workspace creation falls back to the Artemis-2 sim monorepo.
data "coder_parameter" "git_repo" {
  name         = "git_repo"
  display_name = "Git Repository"
  description  = "Repository to clone on workspace start. Bridge service overrides per-issue; default points at the Artemis-2 sim monorepo."
  type         = "string"
  default      = "https://gitlab.rhsummit.coderdemo.io/alice/artemis-sim"
  mutable      = false
  icon         = "/icon/git.svg"
}

# -----------------------------------------------------------------------------
# Agent — startup script (no AI tooling)
# -----------------------------------------------------------------------------

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  # The startup script runs on every workspace start. It:
  #   1. Sets up PATH for npm global bin + ~/.local/bin
  #   2. Persists PATH in ~/.profile so login shells / Coder terminals see it
  #   3. Writes a one-time ~/.gitconfig from the workspace owner's identity
  #
  # Note: cmake / clang / gdb / node / npm are baked into the base image
  # (ubi9-node-workspace, with the C++ toolchain layer). Nothing
  # installer-style needs to run here.
  startup_script = <<-EOT
    #!/bin/bash
    touch ~/.bashrc

    # Set up PATH for this script (npm global bin + ~/.local/bin)
    NPM_BIN="$(npm config get prefix 2>/dev/null)/bin"
    export PATH="$HOME/.local/bin:$NPM_BIN:$PATH"

    # Persist PATH additions in .profile (sourced by login shells / Coder terminal)
    for P in "$HOME/.local/bin" "$NPM_BIN"; do
      [ -z "$P" ] && continue
      grep -qF "$P" ~/.profile 2>/dev/null || echo "export PATH=\"$P:\$PATH\"" >> ~/.profile
    done

    # Point npm globals at the user's HOME so subsequent `npm install -g`
    # invocations don't need sudo. Without this they default to /usr and
    # fail under restricted-v2 (CAP_SETUID dropped → sudo can't elevate).
    npm config set prefix "$HOME/.local" >/dev/null 2>&1 || true

    # One-time git identity from the workspace owner — only written if no
    # ~/.gitconfig exists yet (dotfiles or manual edits win after that).
    if [ ! -f ~/.gitconfig ]; then
      echo "Seeding ~/.gitconfig from workspace owner identity..."
      cat > ~/.gitconfig << 'GITCONFIG'
    [user]
        name = ${coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)}
        email = ${data.coder_workspace_owner.me.email}
    [init]
        defaultBranch = main
    GITCONFIG
    fi

    echo "=== Workspace Ready ==="
  EOT

  # Environment variables available to all processes in the workspace.
  # GITLAB_TOKEN / GITLAB_USER are required by the git-clone module to
  # authenticate against private repos on the self-hosted GitLab.
  env = {
    EDITOR       = "code"
    VISUAL       = "code"
    GITLAB_TOKEN = data.coder_external_auth.gitlab.access_token
    GITLAB_USER  = data.coder_workspace_owner.me.name
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

# --- Web IDE ---

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
  default_dotfiles_uri    = "https://github.com/ausbru87/dotfiles"
  default_dotfiles_branch = "main"
}

# git-clone — clone the assigned repo into /home/coder on workspace start.
# GITLAB_TOKEN on the agent env handles private-repo auth.
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
