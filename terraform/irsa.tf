###############################################################################
# IAM roles for cluster workloads
#
# Replaces static IAM users + access keys with IAM roles and STS
# AssumeRole. Pods use EC2 instance metadata (IMDS) as base
# credentials, then chain-assume into a scoped service role.
#
# Why roles instead of users:
#   - No long-lived static credentials stored in K8s Secrets or TF state.
#   - Compatible with AWS accounts that enforce MFA on IAM users (MFA
#     context is absent from access keys used by pods, causing API
#     denials when the account policy requires MFA).
#   - STS-issued temporary credentials auto-expire.
#
# Trust model:
#   Each role trusts the OCP node instance roles (master + worker) that
#   the IPI installer provisions automatically. The bootstrap step adds
#   a scoped sts:AssumeRole inline policy to those node roles so pods
#   can chain-assume into the service role.
#
# Production upgrade path:
#   For per-pod, per-ServiceAccount isolation, switch to full OIDC-based
#   IRSA by installing OCP in credentialsMode: Manual + STS, or deploy
#   the EKS Pod Identity Webhook backed by an S3-hosted OIDC provider.
###############################################################################

###############################################################################
# cert-manager -> Route 53 DNS-01 challenges
#
# cert-manager uses ambient credentials (EC2 IMDS) to AssumeRole into
# this role, then manages Route 53 TXT records for ACME DNS-01 challenges.
# The ClusterIssuer references this role ARN in its `role` field.
###############################################################################

resource "aws_iam_role" "cert_manager" {
  name = "${var.cluster_name}-cert-manager-route53"
  path = "/demo/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowOCPNodeAssume"
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      }
      Action = "sts:AssumeRole"
      Condition = {
        ArnLike = {
          "aws:PrincipalArn" = [
            "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.cluster_name}-*-master-role",
            "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.cluster_name}-*-worker-role",
          ]
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
#
# The Coder pod mounts an AWS shared config file (from ConfigMap
# `bedrock-aws-config`) that sets `role_arn` and
# `credential_source = Ec2InstanceMetadata`. The Go AWS SDK reads this
# config, gets base credentials from IMDS, then AssumeRoles into this
# role for Bedrock API calls.
###############################################################################

resource "aws_iam_role" "coder_bedrock" {
  name = "${var.cluster_name}-coder-bedrock"
  path = "/demo/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowOCPNodeAssume"
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      }
      Action = "sts:AssumeRole"
      Condition = {
        ArnLike = {
          "aws:PrincipalArn" = [
            "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.cluster_name}-*-master-role",
            "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.cluster_name}-*-worker-role",
          ]
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
