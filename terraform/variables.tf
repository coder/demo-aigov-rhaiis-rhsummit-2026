###############################################################################
# AWS / project basics
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy the demo cluster into. Default us-east-1 for the booth — most AZ headroom and the standard region for OCP IPI demos. The VPC is created with one private/public/database subnet per AZ in <region>{a,b,c}."
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
  description = "OpenShift release channel. Use 'stable-4.20' for latest 4.20.x, or pin to a specific 'X.Y.Z'. The openshift-install binary on PATH must match."
  type        = string
  default     = "stable-4.20"
}

variable "openshift_install_binary" {
  description = "Path to the openshift-install binary (4.20+). Defaults to PATH lookup."
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
  description = "EC2 instance type for control plane nodes. m6i.xlarge is the OCP default; bump for SNO."
  type        = string
  default     = "m6i.xlarge"
}

variable "worker_count" {
  description = "Number of compute (worker) nodes. 0 if SNO (control_plane_count=1)."
  type        = number
  default     = 3
}

variable "worker_instance_type" {
  description = "EC2 instance type for compute nodes. m6i.2xlarge fits Coder + RHAIIS + GitOps comfortably."
  type        = string
  default     = "m6i.2xlarge"
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

###############################################################################
# Postgres (Coder DB)
###############################################################################

variable "rds_instance_class" {
  description = "RDS Aurora Postgres instance class. db.t4g.medium is sufficient for demo."
  type        = string
  default     = "db.t4g.medium"
}

variable "rds_engine_version" {
  description = "Aurora Postgres engine version."
  type        = string
  default     = "16.4"
}

###############################################################################
# ECR (workspace base images)
###############################################################################

variable "ecr_repos" {
  description = "List of ECR repositories to create (one per workspace template that needs a custom base image)."
  type        = list(string)
  default     = ["openshift-ai-gov-base"]
}

###############################################################################
# GitHub Actions OIDC (optional)
###############################################################################

variable "github_actions_oidc_role_create" {
  description = "Whether to create the IAM role + OIDC provider trust for GitHub Actions to push to ECR. Set false to skip."
  type        = bool
  default     = true
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the GHA role (e.g., 'coder/demo-aigov-rhaiis-rhsummit-2026')."
  type        = string
  default     = "coder/demo-aigov-rhaiis-rhsummit-2026"
}
