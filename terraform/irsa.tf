###############################################################################
# IAM roles for cluster workloads (IRSA via STS)
#
# OpenShift is installed in credentialsMode: Manual with STS. The ccoctl
# tool creates an S3-hosted OIDC provider and platform IAM roles before
# the cluster installs. The pod identity webhook (included with STS mode)
# injects projected SA tokens into annotated pods.
#
# This file creates additional IAM roles for demo workloads:
#   - cert-manager: Route 53 DNS-01 ACME challenges
#   - Coder Bedrock: AI Gateway -> AWS Bedrock invocations
#
# Each role's trust policy uses sts:AssumeRoleWithWebIdentity scoped to
# a specific Kubernetes ServiceAccount via the OIDC provider. This gives
# per-pod credential isolation (only the annotated SA can assume the role).
###############################################################################

locals {
  oidc_bucket_name  = "${var.cluster_name}-oidc"
  oidc_provider_url = "${local.oidc_bucket_name}.s3.${var.aws_region}.amazonaws.com"
  oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_provider_url}"
}

###############################################################################
# cert-manager -> Route 53 DNS-01 challenges
###############################################################################

resource "aws_iam_role" "cert_manager" {
  name = "${var.cluster_name}-cert-manager-route53"
  path = "/demo/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCertManagerSA"
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:cert-manager:cert-manager"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "cert_manager_route53" {
  name   = "route53-acme-challenge"
  role   = aws_iam_role.cert_manager.name
  policy = data.aws_iam_policy_document.cert_manager_route53.json
}

###############################################################################
# Coder server / AI Gateway -> AWS Bedrock
###############################################################################

resource "aws_iam_role" "coder_bedrock" {
  name = "${var.cluster_name}-coder-bedrock"
  path = "/demo/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCoderSA"
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:coder:coder"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "coder_bedrock" {
  name   = "bedrock-invoke"
  role   = aws_iam_role.coder_bedrock.name
  policy = data.aws_iam_policy_document.coder_bedrock.json
}
