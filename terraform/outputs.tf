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

output "vpc_id" {
  description = "VPC ID for the cluster (BYO-VPC into which OCP IPI installs)."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR. Useful for security-group rules and peering."
  value       = module.vpc.vpc_cidr_block
}

output "vpc_private_subnet_ids" {
  description = "Private subnet IDs (one per AZ). OCP nodes land here."
  value       = module.vpc.private_subnets
}

output "vpc_public_subnet_ids" {
  description = "Public subnet IDs (one per AZ). NAT gateways + ELBs land here."
  value       = module.vpc.public_subnets
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider created by ccoctl for STS. Used by workload IAM role trust policies."
  value       = local.oidc_provider_arn
}

output "cert_manager_role_arn" {
  description = "IAM role ARN used by cert-manager for Route 53 DNS-01 challenges via IRSA."
  value       = aws_iam_role.cert_manager.arn
}

output "coder_bedrock_role_arn" {
  description = "IAM role ARN used by the Coder server pod for AWS Bedrock invocations via IRSA."
  value       = aws_iam_role.coder_bedrock.arn
}

output "bedrock_model_access_url" {
  description = "Direct link to the Bedrock model-access page in the AWS console for this region. You must one-time-approve Anthropic models here before AI Gateway can invoke them."
  value       = "https://${var.aws_region}.console.aws.amazon.com/bedrock/home?region=${var.aws_region}#/modelaccess"
}

output "next_steps" {
  description = "Post-apply checklist."
  value       = <<-EOT

    ==============================================================
    Cluster up (STS mode with IRSA). Next steps:
    ==============================================================

    1. Set kubeconfig in your shell:
         export KUBECONFIG=$(terraform output -raw kubeconfig_path)

    2. Verify the cluster is using STS credentials:
         oc get secrets -n openshift-image-registry installer-cloud-credentials \
           -o jsonpath='{.data.credentials}' | base64 -d
         # Should show role_arn + web_identity_token_file (not access keys)

    3. Verify Argo CD is running:
         oc get pods -n openshift-gitops

    4. Watch the app-of-apps sync:
         oc get applications -n openshift-gitops -w

    5. Verify IRSA annotations on workload SAs:
         oc get sa cert-manager -n cert-manager -o jsonpath='{.metadata.annotations}'
         oc get sa coder -n coder -o jsonpath='{.metadata.annotations}'

    6. Access the OCP console (kubeadmin password in auth dir):
         open $(terraform output -raw cluster_console_url 2>/dev/null || echo "see cluster_console_url output")

    7. Request Bedrock model access (one-time, per-region):
         open $(terraform output -raw bedrock_model_access_url)
         # Approve Anthropic Claude Sonnet 4.x for this region.

    8. Set Coder URL + admin token as GH Actions secrets:
         gh secret set CODER_URL --body "$(terraform output -raw coder_url)"
         gh secret set CODER_SESSION_TOKEN --body "<token>"

    9. Smoke-test RHAIIS tool-calling:
         ../scripts/tool-call-smoke-test.sh \\
           "$(terraform output -raw rhaiis_internal_url)" \\
           granite-3.1-8b-instruct

  EOT
}
