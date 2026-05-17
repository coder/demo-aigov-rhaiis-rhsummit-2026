###############################################################################
# AWS / project basics
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy the demo cluster into. Default us-east-1 for the booth — most AZ headroom and the standard region for OCP IPI demos. The VPC is created with one private/public subnet per AZ in <region>{a,b,c}."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile name (leave null to use default credential chain)."
  type        = string
  default     = null
}

variable "owner_email" {
  description = "Email used in resource tagging (Owner). Use your @coder.com email."
  type        = string
  default     = "austen@coder.com"
}

###############################################################################
# OpenShift cluster
###############################################################################

variable "cluster_name" {
  description = "OCP cluster name. Must be DNS-safe (lowercase, hyphens). Joined with base_domain to form FQDN."
  type        = string
  default     = "cluster"
}

variable "base_domain" {
  description = "Public Route 53 hosted zone you control (e.g., rh.coderdemo.io). The cluster FQDN will be <cluster_name>.<base_domain>."
  type        = string
}

variable "openshift_version" {
  description = "OpenShift release channel. Use 'stable-4.21' for latest 4.21.x, or pin to a specific 'X.Y.Z'. The openshift-install binary on PATH must match."
  type        = string
  default     = "stable-4.21"
}

variable "openshift_install_binary" {
  description = "Path to the openshift-install binary (4.21+). Defaults to PATH lookup."
  type        = string
  default     = "openshift-install"
}

variable "oc_binary" {
  description = "Path to the oc binary. Defaults to PATH lookup."
  type        = string
  default     = "oc"
}

variable "install_dir" {
  description = "Directory used by openshift-install for state. Cluster auth (kubeconfig, kubeadmin password) lands in <install_dir>/auth/. Treat as sensitive."
  type        = string
  default     = "./.cluster"
}

variable "pull_secret_path" {
  description = "Path to your Red Hat pull secret JSON (download from console.redhat.com/openshift/install/pull-secret)."
  type        = string
}

variable "ssh_pubkey_path" {
  description = "Path to the SSH public key (e.g., ~/.ssh/id_ed25519.pub) installed on OCP nodes for break-glass access."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "control_plane_count" {
  description = "Number of control plane nodes. 3 is standard; 1 enables Single-Node OpenShift (cheapest demo)."
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3], var.control_plane_count)
    error_message = "control_plane_count must be 1 (SNO) or 3 (HA)."
  }
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for control plane nodes. Default m6i.4xlarge for the compact 3-node converged cluster (CP nodes also schedulable; need headroom for OCP system + Coder + CNPG + workspaces)."
  type        = string
  default     = "m6i.4xlarge"
}

variable "worker_count" {
  description = "Number of general-compute (worker) nodes. Default 0 — converged cluster pattern: control-plane nodes are also schedulable. Set >0 only if you want a dedicated worker pool in addition to the converged + GPU nodes."
  type        = number
  default     = 0
}

variable "worker_instance_type" {
  description = "EC2 instance type for general-compute nodes (only used when worker_count > 0)."
  type        = string
  default     = "m6i.2xlarge"
}

###############################################################################
# GPU compute pool — hosts RHAIIS (vllm-cuda-rhel9)
###############################################################################

variable "enable_gpu" {
  description = "Whether to provision a GPU MachineSet + run RHAIIS. Catalog default is false (cheaper — ~$3/hr vs ~$10/hr). Set true to enable the sovereign Llama inference path (vLLM on L40S 48 GiB). When false, chatd uses Bedrock-only for chat; the rest of the demo (Coder, Bridge, GitLab, Keycloak, observability) is unaffected."
  type        = bool
  default     = false
}

variable "gpu_count" {
  description = "Number of GPU worker nodes when enable_gpu=true. RHAIIS always runs on the GPU node when present. Ignored if enable_gpu=false."
  type        = number
  default     = 1
}

variable "gpu_instance_type" {
  description = "EC2 instance type for the GPU worker. g5.2xlarge has 1× A10G (24 GiB VRAM), 8 vCPU, 32 GiB RAM — fits Granite-3.1-8B-Instruct fp16 with headroom. Cheaper alternative: g4dn.2xlarge (T4, 16 GiB VRAM)."
  type        = string
  default     = "g5.2xlarge"
}

variable "gpu_zone_index" {
  description = "Index into the AZ list (0..2) where the GPU node will live. g5 capacity is uneven across AZs; pinning to one predictable AZ avoids surprises at boot."
  type        = number
  default     = 0
}

variable "rhaiis_quant" {
  description = "Quantization for the sovereign Llama 3.3 70B model on RHAIIS. 'int4' (default) uses RedHatAI/Llama-3.3-70B-Instruct-quantized.w4a16 — known-good on L40S 48 GiB with the 4-flag recipe (VLLM_USE_V1=0, --gpu-memory-utilization 0.95, --max-model-len 8192, --enforce-eager). 'fp8' uses RedHatAI/Meta-Llama-3.1-70B-Instruct-FP8-dynamic — better quality but currently has AZ-specific capacity issues on g6e.12xlarge. 'none' disables sovereign Llama entirely (chatd uses Bedrock-only)."
  type        = string
  default     = "int4"

  validation {
    condition     = contains(["int4", "fp8", "none"], var.rhaiis_quant)
    error_message = "rhaiis_quant must be 'int4', 'fp8', or 'none'."
  }
}

###############################################################################
# Coder
###############################################################################

variable "coder_chart_version" {
  description = "Coder Helm chart version. Pinned to a stable release. Coder Agents promoted from Early Access experiment to beta in v2.33.1 (PR #24432) — `CODER_EXPERIMENTS=agents` no longer required. Bump only when a newer minor or patch ships and we've validated AI Bridge / agents continuity."
  type        = string
  default     = "2.33.1"
}

variable "coder_image_tag" {
  description = "Coder server container image tag. Should match coder_chart_version's app version."
  type        = string
  default     = "v2.33.1"
}

variable "coder_subdomain" {
  description = "Subdomain Coder is exposed at, joined with base_domain. Default: 'coder' → coder.<cluster_name>.<base_domain> via OCP wildcard route."
  type        = string
  default     = "coder"
}

variable "coder_oidc_provider_url" {
  description = "OIDC issuer for Coder SSO. Leave empty to skip OIDC for the demo (use built-in user/pass)."
  type        = string
  default     = ""
}

# GitHub OAuth credentials for Coder SSO are NOT a Terraform variable.
# They live in the `coder-secrets` SealedSecret at
# manifests/secrets/coder-secrets.yaml — sealed by an operator with
# kubeseal, decrypted in-cluster by the Bitnami controller. See
# docs/secrets.md for the workflow and docs/decisions.md §19 for why.

###############################################################################
# GitLab (self-hosted on EC2) — see terraform/gitlab.tf + terraform/gitlab/
#
# GitLab is the SCM for the demo-persona flow (alice/bob/carol/dave work
# against GitLab issues, NOT GitHub). Runs on a separate EC2 VM rather
# than in-cluster — 5-min Omnibus install vs 30-45 min Helm on OCP, zero
# cluster resource contention, failure-isolated. See
# docs/identity-architecture.md for the full architecture.
###############################################################################

variable "gitlab_enabled" {
  description = "Whether to provision the GitLab EC2 VM. Set false to skip during dev iteration. Default true."
  type        = bool
  default     = true
}

variable "gitlab_instance_type" {
  description = "EC2 instance type for the GitLab VM. m7a.2xlarge (8 vCPU AMD Genoa, 32 GiB, ~$0.46/hr) is the sweet spot for GitLab CE + 2-3 Docker runners on the same host."
  type        = string
  default     = "m7a.2xlarge"
}

variable "gitlab_ami_id" {
  description = "AMI ID for the GitLab VM. Default is the latest Amazon Linux 2023 x86_64 (May 2026). Bump when AL2023 ships a newer minor."
  type        = string
  default     = "ami-0a59ec92177ec3fad"
}

variable "gitlab_ssh_key_name" {
  description = "EC2 KeyPair name for SSH access to the GitLab VM. Create out-of-band via AWS Console or `aws ec2 import-key-pair`."
  type        = string
  default     = ""
}

variable "gitlab_ssh_ingress_cidr" {
  description = "CIDR allowed to SSH (port 22) to the GitLab VM. Default 0.0.0.0/0 — narrow this to your office IP in terraform.tfvars before applying to prod."
  type        = string
  default     = "0.0.0.0/0"
}

variable "gitlab_keycloak_oidc_client_secret" {
  description = "OIDC client secret for the `gitlab` client in the Keycloak `demo` realm. Hardcoded in manifests/keycloak/realm-demo.yaml as 'gitlab-client-secret-demo-2026' — pass the same value here so cloud-init wires the right secret into gitlab.rb's omniauth_providers config."
  type        = string
  default     = "gitlab-client-secret-demo-2026"
  sensitive   = true
}

variable "gitlab_root_password" {
  description = "Initial password for GitLab's `root` user. Primary booth login is Keycloak SSO; root is for emergency console access only (e.g. when SSO is misconfigured). Set in terraform.tfvars."
  type        = string
  sensitive   = true
  default     = "ChangeMeBeforeApply2026!"
}
