# GitLab CE on EC2 — booth-grade SCM.
#
# Single VM running GitLab Omnibus + Docker (for GitLab Runners on the
# same host). Lives in the cluster's VPC but on a public subnet so booth
# laptops + the cluster's in-pod webhook callbacks can both reach it
# via the public DNS name (`gitlab.<base_domain>`).
#
# This is a sub-module under `terraform/gitlab/` — see that directory's
# main.tf for the EC2 + SG + EBS + Route 53 wiring and userdata.sh.tpl
# for the cloud-init that installs gitlab-ce + Docker + runners and
# configures OIDC against the Keycloak demo realm.
#
# Disable this module entirely by setting `gitlab_enabled = false` in
# terraform.tfvars (default: true).

module "gitlab" {
  count  = var.gitlab_enabled ? 1 : 0
  source = "./gitlab"

  cluster_name = var.cluster_name
  base_domain  = var.base_domain
  aws_region   = var.aws_region
  vpc_id       = module.vpc.vpc_id
  # First public subnet — same AZ as the primary GPU node + the rest
  # of the cluster's pre-pinned-to-1a workload.
  public_subnet_id = module.vpc.public_subnets[0]
  instance_type    = var.gitlab_instance_type
  ami_id           = var.gitlab_ami_id
  ssh_key_name     = var.gitlab_ssh_key_name
  ssh_ingress_cidr = var.gitlab_ssh_ingress_cidr

  # OIDC client secret — must match the value in
  # manifests/keycloak/realm-demo.yaml's `gitlab` client. See the
  # comment in that file for the booth-grade hardcoded-secret rationale.
  keycloak_oidc_client_secret = var.gitlab_keycloak_oidc_client_secret
  gitlab_root_password        = var.gitlab_root_password
}

###############################################################################
# Outputs (top-level so `terraform output` surfaces them)
###############################################################################

output "gitlab_url" {
  description = "GitLab CE public URL (empty if gitlab_enabled = false)."
  value       = var.gitlab_enabled ? module.gitlab[0].gitlab_url : ""
}

output "gitlab_public_ip" {
  description = "GitLab EC2 public IP — for SSH troubleshooting."
  value       = var.gitlab_enabled ? module.gitlab[0].gitlab_public_ip : ""
}

output "gitlab_registry_url" {
  description = "GitLab container registry URL — same EC2 host, separate Omnibus vhost (registry.gitlab.<base_domain>). Empty if gitlab_enabled = false."
  value       = var.gitlab_enabled ? module.gitlab[0].registry_url : ""
}
