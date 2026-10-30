output "gitlab_url" {
  description = "Public HTTPS URL of the GitLab CE instance."
  value       = "https://${local.gitlab_hostname}"
}

output "gitlab_hostname" {
  description = "DNS hostname (without scheme) — used by GitLab's webhook + OIDC callback paths."
  value       = local.gitlab_hostname
}

output "registry_url" {
  description = "GitLab container registry URL. Use as the registry host for `docker login` / `podman login` from inside Coder workspaces and from CI runners."
  value       = "https://${local.registry_hostname}"
}

output "registry_hostname" {
  description = "DNS hostname (without scheme) of the GitLab container registry — same EC2 instance, separate Omnibus vhost + LE cert."
  value       = local.registry_hostname
}

output "gitlab_public_ip" {
  description = "EC2 public IP — empty now that GitLab is on a private subnet (no public IP). Kept for output-contract back-compat; use gitlab_private_ip + SSM Session Manager for ops."
  value       = aws_instance.gitlab.public_ip
}

output "gitlab_private_ip" {
  description = "EC2 private IP (pinned). This is the address the OpenShift Route's EndpointSlice targets. Reach the host for ops via: aws ssm start-session --target <gitlab_instance_id>."
  value       = aws_instance.gitlab.private_ip
}

output "gitlab_instance_id" {
  description = "EC2 instance ID. For aws-cli operations + 1Password reference."
  value       = aws_instance.gitlab.id
}

output "gitlab_root_password" {
  description = "Initial root password (emergency console access only — primary login is Keycloak SSO). Mark sensitive."
  value       = var.gitlab_root_password
  sensitive   = true
}
