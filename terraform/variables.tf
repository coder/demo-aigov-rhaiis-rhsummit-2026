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

variable "gpu_count" {
  description = "Number of GPU worker nodes. Default 1 — RHAIIS always runs on the GPU node, every time the cluster is up. Set 0 only if you're temporarily disabling GPU and have a CPU fallback path for RHAIIS (not currently shipped in this repo)."
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

###############################################################################
# Coder
###############################################################################

variable "coder_chart_version" {
  description = "Coder Helm chart version. We pin to a release-candidate to get Coder Agents Early Access plus the chatd metrics, edit_files newline-strict diffs, per-turn model persistence, and agents-access org-scoped role migration that landed for this RC. Bump only when a newer tagged RC ships (RC tags now live directly on main; main HEAD is not necessarily a tagged RC)."
  type        = string
  default     = "2.33.0-rc.3"
}

variable "coder_image_tag" {
  description = "Coder server container image tag. Should match coder_chart_version's app version."
  type        = string
  default     = "v2.33.0-rc.3"
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
