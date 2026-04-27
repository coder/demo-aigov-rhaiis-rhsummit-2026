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

output "cert_manager_role_arn" {
  description = "IAM role ARN used by cert-manager to perform Route 53 DNS-01 challenges via AssumeRole. Injected into the ClusterIssuer by the bootstrap step."
  value       = aws_iam_role.cert_manager.arn
}

output "coder_bedrock_role_arn" {
  description = "IAM role ARN used by the Coder server pod for AWS Bedrock invocations (via AI Gateway). Injected into ConfigMap `bedrock-aws-config` in the `coder` namespace by the bootstrap step."
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
    Cluster up. Next steps:
    ==============================================================

    1. Set kubeconfig in your shell:
         export KUBECONFIG=$(terraform output -raw kubeconfig_path)

    2. Verify Argo CD is running:
         oc get pods -n openshift-gitops

    3. Watch the app-of-apps sync (postgres at wave 0 stands up the
       in-cluster CNPG Cluster — it auto-generates the `coder-app`
       Secret that Coder consumes at wave 1):
         oc get applications -n openshift-gitops -w

    4. Access the OCP console (kubeadmin password in auth dir):
         open $(terraform output -raw cluster_console_url 2>/dev/null || echo "see cluster_console_url output")

    5. Request Bedrock model access (one-time, per-region):
         open $(terraform output -raw bedrock_model_access_url)
         # Approve Anthropic Claude Sonnet 4.x for this region.

    6. Set Coder URL + admin token as GH Actions secrets so
       push-templates.yml can publish template changes:
         gh secret set CODER_URL --body "$(terraform output -raw coder_url)"
         # Log in as admin in browser, copy token, then:
         gh secret set CODER_SESSION_TOKEN --body "<token>"

    7. Push your first template (images build + publish to GHCR via
       .github/workflows/build-images.yml using GITHUB_TOKEN — no AWS
       OIDC required):
         git add coder-templates/
         git commit -m "feat(template): initial template"
         git push origin main

    8. Smoke-test RHAIIS tool-calling:
         ../scripts/tool-call-smoke-test.sh \\
           "$(terraform output -raw rhaiis_internal_url)" \\
           granite-3.1-8b-instruct

  EOT
}
