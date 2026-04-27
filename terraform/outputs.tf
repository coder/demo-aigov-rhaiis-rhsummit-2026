output "cluster_api_url" {
  description = "OpenShift API server URL."
  value       = "https://api.${var.cluster_name}.${var.base_domain}:6443"
}

output "cluster_console_url" {
  description = "OpenShift web console URL."
  value       = "https://console-openshift-console.apps.${var.cluster_name}.${var.base_domain}"
}

output "coder_url" {
  description = "Coder URL. Set this as the CODER_URL secret for GH Actions."
  value       = "https://${var.coder_subdomain}.apps.${var.cluster_name}.${var.base_domain}"
}

output "rhaiis_internal_url" {
  description = "Cluster-internal RHAIIS / vLLM endpoint (use as AI Gateway sovereign provider base URL)."
  value       = "http://vllm.ocp-ai.svc:8000/v1"
}

output "kubeconfig_path" {
  description = "Path to the cluster kubeconfig. Use with: export KUBECONFIG=$(terraform output -raw kubeconfig_path)"
  value       = "${var.install_dir}/auth/kubeconfig"
}

output "kubeadmin_password_path" {
  description = "Path to the kubeadmin initial password file."
  value       = "${var.install_dir}/auth/kubeadmin-password"
  sensitive   = true
}

output "rds_endpoint" {
  description = "Aurora Postgres writer endpoint."
  value       = aws_rds_cluster.coder.endpoint
}

output "rds_database_name" {
  description = "Aurora Postgres database name for Coder."
  value       = aws_rds_cluster.coder.database_name
}

output "ecr_repo_urls" {
  description = "Map of ECR repo name → repo URL for workspace base images."
  value       = { for r in aws_ecr_repository.workspace : r.name => r.repository_url }
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions to assume via OIDC (set as GHA repo variable AWS_ROLE_ARN)."
  value       = var.github_actions_oidc_role_create ? aws_iam_role.gha[0].arn : null
}

output "next_steps" {
  description = "Post-apply checklist."
  value       = <<-EOT

    ==============================================================
    Cluster up. Next steps:
    ==============================================================

    1. Set kubeconfig in your shell:
         export KUBECONFIG=$(terraform output -raw kubeconfig_path)

    2. Verify Argo CD is running:
         oc get pods -n openshift-gitops

    3. Access the OCP console (kubeadmin password in auth dir):
         open $(terraform output -raw cluster_console_url 2>/dev/null || echo "see cluster_console_url output")

    4. Wait for Argo CD root app to sync (Coder + RHAIIS + agent-firewalls):
         oc get applications -n openshift-gitops -w

    5. Get Coder URL + admin token, set GH Actions secrets:
         gh secret set CODER_URL --body "$(terraform output -raw coder_url)"
         # Log in as admin in browser, copy token, then:
         gh secret set CODER_SESSION_TOKEN --body "<token>"
         gh variable set AWS_ROLE_ARN --body "$(terraform output -raw github_actions_role_arn)"

    6. Push your first template:
         git add coder-templates/
         git commit -m "feat(template): initial template"
         git push origin main

    7. Smoke-test RHAIIS tool-calling:
         ../scripts/tool-call-smoke-test.sh \\
           "$(terraform output -raw rhaiis_internal_url)" \\
           granite-3.1-8b-instruct

  EOT
}
