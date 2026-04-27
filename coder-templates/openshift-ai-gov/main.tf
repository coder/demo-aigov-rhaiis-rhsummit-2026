# Coder workspace template — openshift-ai-gov
#
# A demo workspace for the Red Hat Summit 2026 booth. Lands on OpenShift
# with the AI Governance Add-On wiring already in place:
#   - AI Gateway URL exported as OPENAI_API_BASE
#   - Sovereign route to RHAIIS available via the same gateway
#   - Coder Tasks ready (background agent execution)
#   - Coder Agents (EA) governs the agent loop from the control plane
#
# Push to live Coder via:
#   coder templates push openshift-ai-gov --directory . --yes
#
# Or via .github/workflows/push-templates.yml on push to main.

terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

provider "coder" {}

provider "kubernetes" {
  # Coder runs in-cluster against the same OpenShift cluster — use in-cluster
  # service-account credentials at workspace-build time.
}

###############################################################################
# Parameters surfaced to workspace owners
###############################################################################

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  description  = "Cores requested for the workspace pod."
  default      = "2"
  type         = "number"
  mutable      = true
  validation {
    min = 1
    max = 8
  }
}

data "coder_parameter" "memory_gb" {
  name         = "memory_gb"
  display_name = "Memory (GiB)"
  description  = "Memory requested for the workspace pod."
  default      = "4"
  type         = "number"
  mutable      = true
  validation {
    min = 2
    max = 32
  }
}

data "coder_parameter" "image" {
  name         = "image"
  display_name = "Workspace base image"
  description  = "ECR-hosted base image (built from images/Dockerfile in this template's directory)."
  default      = "openshift-ai-gov-base:latest"
  type         = "string"
  mutable      = true
}

###############################################################################
# Variables (set at template push time, not per-workspace)
###############################################################################

variable "namespace" {
  description = "Kubernetes namespace where workspace pods land."
  type        = string
  default     = "coder-workspaces"
}

variable "ecr_registry" {
  description = "ECR registry domain (from `terraform output -raw ecr_repo_urls`). e.g., 123456789012.dkr.ecr.us-east-1.amazonaws.com"
  type        = string
  default     = "TBD-ECR-REGISTRY"
}

variable "ai_gateway_url" {
  description = "AI Gateway internal URL (Coder service)."
  type        = string
  default     = "http://coder.coder.svc.cluster.local:7080/v1"
}

###############################################################################
# Coder data sources
###############################################################################

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

###############################################################################
# Coder agent
###############################################################################

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = <<-EOT
    set -euo pipefail

    # AI Gateway wiring — every model call from this workspace goes through
    # AI Gateway, gets logged, and is policy-checked by Agent Firewalls.
    export OPENAI_API_BASE="${var.ai_gateway_url}"
    export OPENAI_API_KEY="${data.coder_workspace_owner.me.session_token}"

    # Persist for shells started later (vscode terminals, etc.)
    cat <<EOF >> $HOME/.bashrc
    export OPENAI_API_BASE="${var.ai_gateway_url}"
    export OPENAI_API_KEY="${data.coder_workspace_owner.me.session_token}"
    EOF

    # code-server (browser VS Code)
    if ! command -v code-server >/dev/null 2>&1; then
      curl -fsSL https://code-server.dev/install.sh | sh
    fi
    code-server --auth none --bind-addr 0.0.0.0:13337 &
  EOT

  metadata {
    display_name = "CPU usage"
    key          = "cpu"
    script       = "top -bn1 | grep 'Cpu(s)' | awk '{print $2 + $4}'"
    interval     = 30
    timeout      = 5
  }

  metadata {
    display_name = "Memory"
    key          = "memory"
    script       = "free -h | awk '/Mem/ { print $3 \"/\" $2 }'"
    interval     = 30
    timeout      = 5
  }
}

resource "coder_app" "code" {
  agent_id     = coder_agent.main.id
  slug         = "code"
  display_name = "VS Code (browser)"
  url          = "http://localhost:13337"
  icon         = "/icon/code.svg"
  subdomain    = true
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 10
    threshold = 6
  }
}

###############################################################################
# Agent Firewall — config setup at workspace start
#
# Per https://coder.com/docs/ai-coder/agent-firewall, the firewall reads
# its allowlist from ~/.config/coder_boundary/config.yaml. We bundle the
# config alongside main.tf and install it into the workspace via a
# coder_script that runs on every workspace start. base64-encoding the
# file content keeps the heredoc portable across shells.
###############################################################################

resource "coder_script" "boundary_config_setup" {
  agent_id     = coder_agent.main.id
  display_name = "Agent Firewall config setup"
  run_on_start = true
  script       = <<-EOF
    #!/bin/sh
    set -eu
    mkdir -p "$HOME/.config/coder_boundary"
    echo '${base64encode(file("${path.module}/config.yaml"))}' | base64 -d > "$HOME/.config/coder_boundary/config.yaml"
    chmod 600 "$HOME/.config/coder_boundary/config.yaml"
    echo "Agent Firewall config installed at $HOME/.config/coder_boundary/config.yaml"
  EOF
}

###############################################################################
# Workspace Pod
###############################################################################

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"      = "coder-workspace"
      "app.kubernetes.io/part-of"   = "coder-aigov-demo"
      "coder.workspace.id"          = data.coder_workspace.me.id
      "coder.workspace.owner"       = data.coder_workspace_owner.me.name
    }
  }

  spec {
    restart_policy = "Always"

    container {
      name              = "dev"
      image             = "${var.ecr_registry}/demo-aigov/${data.coder_parameter.image.value}"
      image_pull_policy = "Always"
      command           = ["sh", "-c", coder_agent.main.init_script]

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      resources {
        requests = {
          cpu    = "${data.coder_parameter.cpu.value * 500}m"
          memory = "${data.coder_parameter.memory_gb.value * 0.5}Gi"
        }
        limits = {
          cpu    = "${data.coder_parameter.cpu.value}"
          memory = "${data.coder_parameter.memory_gb.value}Gi"
        }
      }
    }
  }
}
