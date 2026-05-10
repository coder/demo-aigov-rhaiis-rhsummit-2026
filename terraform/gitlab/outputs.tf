output "gitlab_url" {
  description = "Public HTTPS URL of the GitLab CE instance."
  value       = "https://${local.gitlab_hostname}"
}

output "gitlab_hostname" {
  description = "DNS hostname (without scheme) — used by GitLab's webhook + OIDC callback paths."
  value       = local.gitlab_hostname
}

output "gitlab_public_ip" {
  description = "EC2 public IP. Useful for SSH troubleshooting."
  value       = aws_instance.gitlab.public_ip
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
