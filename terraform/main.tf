###############################################################################
# OpenShift IPI install + supporting AWS infra (Aurora Postgres, ECR, GHA OIDC)
#
# Flow:
#   1. Read pull secret + ssh public key
#   2. Create RDS Aurora Postgres (Coder DB) — independent of cluster
#   3. Create ECR repos for workspace base images
#   4. Optionally create IAM role + OIDC provider for GitHub Actions
#   5. Render install-config.yaml from template into <install_dir>
#   6. Run `openshift-install create cluster --dir=<install_dir>` (~30–45 min)
#   7. Install OpenShift GitOps operator + bootstrap Argo CD root Application
#
# `terraform destroy` runs `openshift-install destroy cluster` first, then
# tears down RDS / ECR / IAM. The cluster install dir is preserved on disk
# for debugging — wipe it manually after destroy if you need a clean slate.
#
# IMPORTANT: openshift-install creates its own VPC / subnets / IAM by default.
# We do NOT pre-provision a VPC here; the installer owns that. If you need to
# install into an existing VPC ("BYO-VPC"), edit install-config.yaml.tftpl
# accordingly per the OCP IPI docs.
###############################################################################

###############################################################################
# Data sources
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_route53_zone" "base" {
  name         = var.base_domain
  private_zone = false
}

data "local_file" "pull_secret" {
  filename = pathexpand(var.pull_secret_path)
}

data "local_file" "ssh_pubkey" {
  filename = pathexpand(var.ssh_pubkey_path)
}

###############################################################################
# RDS Aurora Postgres for Coder — multi-AZ (writer + reader)
#
# Lives in the BYO-VPC private database subnets. Reachable from OCP nodes
# inside the same VPC; NOT publicly accessible. ESO + Coder pods reach it
# via the VPC's internal DNS.
###############################################################################

resource "random_password" "rds" {
  length  = 24
  special = false
}

resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds"
  description = "RDS Aurora — Coder DB. Allow Postgres from any host in the cluster VPC."
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${var.cluster_name}-rds"
  }
}

resource "aws_security_group_rule" "rds_ingress_postgres" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = [module.vpc.vpc_cidr_block]
  security_group_id = aws_security_group.rds.id
  description       = "Postgres from any host in the cluster VPC"
}

resource "aws_security_group_rule" "rds_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.rds.id
  description       = "Allow egress for engine logs / monitoring"
}

resource "aws_rds_cluster" "coder" {
  cluster_identifier      = "${var.cluster_name}-coder-db"
  engine                  = "aurora-postgresql"
  engine_mode             = "provisioned"
  engine_version          = var.rds_engine_version
  database_name           = "coder"
  master_username         = "coder"
  master_password         = random_password.rds.result
  backup_retention_period = 7         # bumped from demo-1 for HA posture
  skip_final_snapshot     = true      # demo only — set false + final_snapshot_identifier for prod
  storage_encrypted       = true
  deletion_protection     = false     # demo

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]
  availability_zones     = local.vpc_azs

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 4.0
  }
}

# Writer instance — AZ 1 of 3
resource "aws_rds_cluster_instance" "coder_writer" {
  cluster_identifier   = aws_rds_cluster.coder.id
  identifier           = "${var.cluster_name}-coder-db-writer"
  instance_class       = "db.serverless"
  engine               = aws_rds_cluster.coder.engine
  engine_version       = aws_rds_cluster.coder.engine_version
  publicly_accessible  = false
  promotion_tier       = 0          # primary writer
  availability_zone    = local.vpc_azs[0]
  db_subnet_group_name = module.vpc.database_subnet_group_name
}

# Reader instance — AZ 2 of 3 (failover candidate, also serves read traffic)
resource "aws_rds_cluster_instance" "coder_reader" {
  cluster_identifier   = aws_rds_cluster.coder.id
  identifier           = "${var.cluster_name}-coder-db-reader"
  instance_class       = "db.serverless"
  engine               = aws_rds_cluster.coder.engine
  engine_version       = aws_rds_cluster.coder.engine_version
  publicly_accessible  = false
  promotion_tier       = 1
  availability_zone    = local.vpc_azs[1]
  db_subnet_group_name = module.vpc.database_subnet_group_name
}

###############################################################################
# ECR repos for workspace base images
###############################################################################

resource "aws_ecr_repository" "workspace" {
  for_each             = toset(var.ecr_repos)
  name                 = "demo-aigov/${each.key}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "workspace" {
  for_each   = aws_ecr_repository.workspace
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

###############################################################################
# AWS Secrets Manager — backing store for ESO
#
# Two secrets the cluster needs at sync time:
#   1. coder-db-url     — postgres connection URL for Coder
#   2. redhat-pull-secret — the partner pull-secret JSON for RHAIIS image
#
# Stored here so External Secrets Operator can pull them into the cluster
# as Kubernetes Secrets, eliminating the manual `oc create secret` steps.
#
# AWS SM cost is ~$0.40/secret/month. Two secrets => $0.80/month. Negligible.
###############################################################################

resource "aws_secretsmanager_secret" "coder_db_url" {
  name                    = "demo-aigov/coder-db-url"
  description             = "Postgres connection URL for the Coder control plane (consumed by ESO)."
  recovery_window_in_days = 0   # demo only — drops immediately on destroy
}

resource "aws_secretsmanager_secret_version" "coder_db_url" {
  secret_id = aws_secretsmanager_secret.coder_db_url.id
  # Use the writer endpoint — Coder server writes; reads also go to writer
  # by default. Aurora handles failover by repointing the writer endpoint
  # to the reader instance automatically.
  secret_string = "postgres://coder:${random_password.rds.result}@${aws_rds_cluster.coder.endpoint}:5432/${aws_rds_cluster.coder.database_name}?sslmode=require"

  # Force update if any of the underlying values change (so ESO re-syncs)
  depends_on = [
    aws_rds_cluster_instance.coder_writer,
    aws_rds_cluster_instance.coder_reader,
  ]
}

resource "aws_secretsmanager_secret" "redhat_pull_secret" {
  name                    = "demo-aigov/redhat-pull-secret"
  description             = "Red Hat partner pull-secret JSON (consumed by ESO for RHAIIS image pulls)."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "redhat_pull_secret" {
  secret_id     = aws_secretsmanager_secret.redhat_pull_secret.id
  secret_string = trimspace(data.local_file.pull_secret.content)
}

###############################################################################
# IAM user for External Secrets Operator (ESO) to read AWS Secrets Manager
###############################################################################

data "aws_iam_policy_document" "external_secrets_read" {
  statement {
    sid    = "ReadDemoSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      aws_secretsmanager_secret.coder_db_url.arn,
      aws_secretsmanager_secret.redhat_pull_secret.arn,
    ]
  }
}

resource "aws_iam_user" "external_secrets" {
  name = "${var.cluster_name}-external-secrets"
  path = "/demo/"
}

resource "aws_iam_user_policy" "external_secrets" {
  name   = "secretsmanager-read"
  user   = aws_iam_user.external_secrets.name
  policy = data.aws_iam_policy_document.external_secrets_read.json
}

resource "aws_iam_access_key" "external_secrets" {
  user = aws_iam_user.external_secrets.name
}

###############################################################################
# IAM user for cert-manager Route 53 DNS-01 challenges
#
# cert-manager runs in the cluster and calls Route 53 to create + remove
# `_acme-challenge.<domain>` TXT records during ACME wildcard cert issuance.
# Production should use IRSA (IAM Roles for Service Accounts) instead of
# static keys, but that requires installing OCP in STS / manual cred mode
# which is out of scope for the booth.
#
# Permissions follow the cert-manager docs:
# https://cert-manager.io/docs/configuration/acme/dns01/route53/
###############################################################################

data "aws_iam_policy_document" "cert_manager_route53" {
  statement {
    sid     = "GetChange"
    effect  = "Allow"
    actions = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }
  statement {
    sid     = "ChangeResourceRecordSets"
    effect  = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
    ]
    resources = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.base.zone_id}"]
  }
  statement {
    sid       = "ListHostedZonesByName"
    effect    = "Allow"
    actions   = ["route53:ListHostedZonesByName"]
    resources = ["*"]
  }
}

resource "aws_iam_user" "cert_manager" {
  name = "${var.cluster_name}-cert-manager"
  path = "/demo/"
}

resource "aws_iam_user_policy" "cert_manager_route53" {
  name   = "route53-acme-challenge"
  user   = aws_iam_user.cert_manager.name
  policy = data.aws_iam_policy_document.cert_manager_route53.json
}

resource "aws_iam_access_key" "cert_manager" {
  user = aws_iam_user.cert_manager.name
}

###############################################################################
# IAM role + OIDC provider for GitHub Actions (optional)
###############################################################################

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.github_actions_oidc_role_create ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "gha_assume" {
  count = var.github_actions_oidc_role_create ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "gha" {
  count              = var.github_actions_oidc_role_create ? 1 : 0
  name               = "${var.cluster_name}-gha-ecr"
  assume_role_policy = data.aws_iam_policy_document.gha_assume[0].json
}

resource "aws_iam_role_policy" "gha_ecr" {
  count = var.github_actions_oidc_role_create ? 1 : 0
  name  = "ecr-push"
  role  = aws_iam_role.gha[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
        ]
        Resource = [for r in aws_ecr_repository.workspace : r.arn]
      },
    ]
  })
}

###############################################################################
# Render install-config.yaml from template
###############################################################################

resource "local_sensitive_file" "install_config" {
  filename = "${var.install_dir}/install-config.yaml"
  content = templatefile("${path.module}/install-config.yaml.tftpl", {
    cluster_name                = var.cluster_name
    base_domain                 = var.base_domain
    aws_region                  = var.aws_region
    control_plane_count         = var.control_plane_count
    control_plane_instance_type = var.control_plane_instance_type
    worker_count                = local.effective_worker_count
    worker_instance_type        = var.worker_instance_type
    pull_secret                 = trimspace(data.local_file.pull_secret.content)
    ssh_pubkey                  = trimspace(data.local_file.ssh_pubkey.content)
    machine_cidr                = local.vpc_cidr
    subnet_ids                  = concat(module.vpc.private_subnets, module.vpc.public_subnets)
  })
  file_permission      = "0600"
  directory_permission = "0700"
}

###############################################################################
# Run openshift-install
###############################################################################

resource "null_resource" "openshift_install" {
  depends_on = [local_sensitive_file.install_config]

  triggers = {
    install_dir       = var.install_dir
    install_binary    = var.openshift_install_binary
    install_config_md5 = local_sensitive_file.install_config.content_md5
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      echo "Running openshift-install create cluster (this takes 30–45 min)..."
      ${var.openshift_install_binary} create cluster \
        --dir="${var.install_dir}" \
        --log-level=info
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -euo pipefail
      echo "Running openshift-install destroy cluster..."
      ${self.triggers.install_binary} destroy cluster \
        --dir="${self.triggers.install_dir}" \
        --log-level=info || true
    EOT
  }
}

###############################################################################
# Bootstrap OpenShift GitOps operator + Argo CD root Application
###############################################################################

resource "null_resource" "gitops_bootstrap" {
  depends_on = [null_resource.openshift_install]

  triggers = {
    cluster_id = null_resource.openshift_install.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${var.install_dir}/auth/kubeconfig"

      echo "==> Applying RH-supported + community operator subscriptions (OpenShift GitOps + cert-manager + ESO)..."
      ${var.oc_binary} apply -f ${path.module}/../gitops/operator/

      echo "==> Waiting for openshift-gitops Argo CD server to be Ready..."
      for i in $(seq 1 60); do
        if ${var.oc_binary} get pods -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-server 2>/dev/null | grep -q "Running"; then
          break
        fi
        echo "    ...waiting ($i/60)"
        sleep 10
      done
      ${var.oc_binary} wait --for=condition=Ready pod \
        -l app.kubernetes.io/name=openshift-gitops-server \
        -n openshift-gitops --timeout=600s

      echo "==> Waiting for cert-manager namespace to be created by the operator..."
      for i in $(seq 1 60); do
        if ${var.oc_binary} get namespace cert-manager 2>/dev/null | grep -q Active; then
          break
        fi
        echo "    ...waiting for cert-manager ns ($i/60)"
        sleep 10
      done

      echo "==> Waiting for cert-manager CRDs (ClusterIssuer) to be installed..."
      for i in $(seq 1 60); do
        if ${var.oc_binary} get crd clusterissuers.cert-manager.io 2>/dev/null | grep -q clusterissuers; then
          break
        fi
        echo "    ...waiting for cert-manager CRDs ($i/60)"
        sleep 10
      done

      echo "==> Waiting for External Secrets Operator CRDs..."
      for i in $(seq 1 60); do
        if ${var.oc_binary} get crd externalsecrets.external-secrets.io 2>/dev/null | grep -q externalsecrets; then
          break
        fi
        echo "    ...waiting for ESO CRDs ($i/60)"
        sleep 10
      done

      echo "==> Creating external-secrets namespace if missing..."
      ${var.oc_binary} create namespace external-secrets --dry-run=client -o yaml | ${var.oc_binary} apply -f -

      echo "==> Creating Route 53 credentials Secret in cert-manager namespace..."
      ${var.oc_binary} create secret generic route53-credentials \
        --namespace=cert-manager \
        --from-literal=access-key-id='${aws_iam_access_key.cert_manager.id}' \
        --from-literal=secret-access-key='${aws_iam_access_key.cert_manager.secret}' \
        --dry-run=client -o yaml | ${var.oc_binary} apply -f -

      echo "==> Creating AWS Secrets Manager creds Secret in external-secrets namespace..."
      ${var.oc_binary} create secret generic aws-secrets-manager-creds \
        --namespace=external-secrets \
        --from-literal=access-key-id='${aws_iam_access_key.external_secrets.id}' \
        --from-literal=secret-access-key='${aws_iam_access_key.external_secrets.secret}' \
        --dry-run=client -o yaml | ${var.oc_binary} apply -f -

      echo "==> Bootstrapping Argo CD root Application (app-of-apps)..."
      ${var.oc_binary} apply -f ${path.module}/../gitops/bootstrap/root-app.yaml

      echo "==> GitOps bootstrap complete. Watch sync with:"
      echo "       oc get applications -n openshift-gitops -w"
    EOT
  }
}
