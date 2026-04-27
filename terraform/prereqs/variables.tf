###############################################################################
# AWS / project basics
###############################################################################

variable "aws_region" {
  description = "AWS region for the demo cluster (must match cluster TF aws_region). Default us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile name (leave null for default credential chain)."
  type        = string
  default     = null
}

variable "owner_email" {
  description = "Email used in resource tagging (Owner)."
  type        = string
  default     = "austen@coder.com"
}

variable "cluster_name" {
  description = "OCP cluster name (used in IAM user naming and tags). Must match cluster TF."
  type        = string
  default     = "cluster"
}

###############################################################################
# Route 53
###############################################################################

variable "manage_hosted_zone" {
  description = <<-EOT
    Whether THIS Terraform creates the public Route 53 hosted zone for base_domain.

    true  → create a new public zone for base_domain. After apply, you MUST
            delegate the printed NS records at your registrar (or parent zone)
            BEFORE running the cluster TF, or the OCP installer will fail to
            validate the domain.

    false → assume the zone already exists; we just look it up by name.
  EOT
  type        = bool
  default     = true
}

variable "base_domain" {
  description = "Public DNS zone (e.g., rh.coderdemo.io). Cluster FQDN will be <cluster_name>.<base_domain>."
  type        = string
}

###############################################################################
# IAM — OCP installer user
###############################################################################

variable "create_installer_iam" {
  description = <<-EOT
    Whether to create a dedicated IAM user for the OCP installer.

    true  → creates user `ocp-installer-<cluster_name>` with AdministratorAccess
            and a fresh access key. Outputs the access key ID + secret. USE THIS
            when you want the installer to run with creds separate from your own.

    false → skip; the cluster TF will use whatever AWS profile/creds are active
            in your shell. Simpler but risks tying the cluster's lifecycle to
            your personal credentials.

    NOTE: this provisions an IAM user with long-lived static credentials. That's
    a known anti-pattern outside of demos. For production, use IAM Identity
    Center / SSO + STS AssumeRole and pass role_arn into the cluster TF.
  EOT
  type        = bool
  default     = true
}

variable "installer_iam_policy_arn" {
  description = "Policy attached to the installer user. Defaults to AdministratorAccess (demo). Production should use the documented OCP IPI policy."
  type        = string
  default     = "arn:aws:iam::aws:policy/AdministratorAccess"
}

###############################################################################
# Service quotas
###############################################################################

variable "control_plane_count" {
  description = "Must match the cluster TF. Used to compute required vCPU quota."
  type        = number
  default     = 3
}

variable "control_plane_instance_type" {
  description = "Must match the cluster TF."
  type        = string
  default     = "m6i.xlarge"
}

variable "worker_count" {
  description = "Must match the cluster TF (effective worker count, 0 for SNO)."
  type        = number
  default     = 3
}

variable "worker_instance_type" {
  description = "Must match the cluster TF."
  type        = string
  default     = "m6i.2xlarge"
}

variable "request_quota_increases" {
  description = <<-EOT
    Whether to file quota-increase requests automatically when current quotas
    are below required.

    true  → submits requests via the Service Quotas API. Some quotas auto-
            approve; others require a support case (which AWS can take hours
            to days to resolve). Run this AT LEAST a week before booth day.

    false → just validate; fail apply with a clear error message if any quota
            is too low. You then request increases manually in the AWS console.
  EOT
  type        = bool
  default     = false
}

variable "fail_on_quota_shortfall" {
  description = "If true (default), the apply hard-fails when a required quota is below the computed need. If false, quota issues become warnings — useful when you've already filed increase tickets and are waiting."
  type        = bool
  default     = true
}
