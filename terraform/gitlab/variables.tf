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
  default     = ""
  description = "DEPRECATED (kept for back-compat). GitLab now lives on a PRIVATE subnet behind an OpenShift edge Route — see private_subnet_id. Leave empty."
}

variable "private_subnet_id" {
  type        = string
  description = "Private subnet ID in the cluster's VPC, in the SAME AZ as the EBS data volume (us-east-1a). GitLab has no public IP; it is reached only through the OpenShift edge Route + via SSM Session Manager for ops."
}

variable "private_ip" {
  type        = string
  default     = "10.0.20.10"
  description = "Static private IP for the GitLab VM inside private_subnet_id (must be within that subnet's CIDR and free). Pinned so the OpenShift Route's EndpointSlice is stable/reproducible across instance rebuilds."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "VPC CIDR — the GitLab security group allows HTTP (port 80) only from inside the VPC (the OpenShift router pods), never the public internet."
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

variable "ingress_lb_hostname" {
  type        = string
  default     = ""
  description = "OpenShift router/ingress LB DNS name. When set, Route 53 CNAMEs for gitlab.<base_domain> and registry.gitlab.<base_domain> point here (traffic enters through the OCP edge Routes). Empty => this module manages no DNS (blue/green cutover flips it out-of-band). Get it via: oc -n openshift-ingress get svc router-default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'."
}

variable "ssh_ingress_cidr" {
  type        = string
  default     = ""
  description = "CIDR allowed to SSH (port 22) to the GitLab VM. EMPTY (default) = no public SSH rule at all — operators use SSM Session Manager (the instance has the AmazonSSMManagedInstanceCore profile). Set a specific CIDR (e.g. an office IP /32) only if you need direct SSH; never 0.0.0.0/0 (Security Hub EC2.19/EC2.18). HTTPS (443) is always 0.0.0.0/0 since the booth uses it."
}

variable "keycloak_secret_arn" {
  type        = string
  description = "ARN of the AWS Secrets Manager secret holding the Keycloak demo-realm credentials (JSON). cloud-init fetches the `gitlab_client_secret` key from it at boot via the instance profile (IRSA-free; EC2 instance role) and wires GitLab's `omniauth_providers` config. No OIDC secret is baked into Terraform state or user-data."
}

variable "gitlab_root_password" {
  type        = string
  sensitive   = true
  description = "Initial password for GitLab's `root` user. Set by cloud-init via gitlab-rails console after first boot. The booth workflow logs in via Keycloak SSO, NOT as root — root password is just for emergency console access."
}
