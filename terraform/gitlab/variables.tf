# Variables for the GitLab-on-EC2 sub-module.
#
# All values are passed in from terraform/main.tf — this module
# doesn't read tfvars directly. Reuses the cluster's existing VPC
# + Route 53 hosted zone so we get one Terraform-managed network.

variable "cluster_name" {
  type        = string
  description = "OCP cluster name (used in resource tags + Route 53 record context)."
}

variable "base_domain" {
  type        = string
  description = "Base DNS domain (e.g. `rhsummit.coderdemo.io`). GitLab will live at `gitlab.<base_domain>`."
}

variable "aws_region" {
  type        = string
  description = "AWS region. GitLab VM will live in the first AZ (us-east-1a) for proximity to the cluster's primary GPU node."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID of the cluster's VPC. GitLab launches in the same VPC."
}

variable "public_subnet_id" {
  type        = string
  description = "Public subnet ID in the cluster's VPC, in the same AZ as the primary GPU node. Public so booth laptops can reach GitLab directly."
}

variable "instance_type" {
  type        = string
  default     = "m7a.2xlarge"
  description = "EC2 instance type. m7a.2xlarge = 8 vCPU AMD Genoa + 32 GiB RAM, ~$0.46/hr. Comfortable for GitLab CE + 2-3 Docker runners on the same host."
}

variable "ami_id" {
  type        = string
  default     = "ami-0a59ec92177ec3fad" # AL2023 2023.11, kernel-6.1, x86_64, May 2026
  description = "AMI ID for the GitLab VM. Defaults to the latest Amazon Linux 2023 x86_64 image as of repo HEAD; bump when AL2023 ships a newer minor."
}

variable "data_volume_size_gb" {
  type        = number
  default     = 100
  description = "EBS gp3 volume for /var/opt/gitlab (repo + Postgres data). 100 GiB covers booth demo + room for one or two real-sized repos pushed during the event."
}

variable "ssh_key_name" {
  type        = string
  description = "EC2 KeyPair name for SSH access. Created out-of-band; referenced by name."
}

variable "ssh_ingress_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "CIDR allowed to SSH (port 22) to the GitLab VM. Default open — narrow this in tfvars to your office IP. HTTPS (443) is always 0.0.0.0/0 since the booth uses it."
}

variable "keycloak_oidc_client_secret" {
  type        = string
  sensitive   = true
  description = "OIDC client secret for the `gitlab` client in the Keycloak `demo` realm. Hardcoded in manifests/keycloak/realm-demo.yaml for booth-grade simplicity; passed here so cloud-init can wire GitLab's `omniauth_providers` config."
}

variable "gitlab_root_password" {
  type        = string
  sensitive   = true
  description = "Initial password for GitLab's `root` user. Set by cloud-init via gitlab-rails console after first boot. The booth workflow logs in via Keycloak SSO, NOT as root — root password is just for emergency console access."
}
