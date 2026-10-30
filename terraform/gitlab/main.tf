# GitLab CE on EC2 — booth-grade SCM for the demo persona path.
#
# Single VM running GitLab Omnibus + Docker (for GitLab Runners on the
# same host). NOT in the OpenShift cluster — see decisions §32
# (forthcoming) for the rationale. Short version: 5-min Omnibus install
# vs 30-45 min for Helm/Operator on OCP; zero cluster resource
# contention; failure-isolated; faster reset.
#
# Networking:
#   - Same VPC as the OpenShift cluster (`var.vpc_id`)
#   - Public subnet (`var.public_subnet_id`) so booth laptops + cluster
#     pods both reach GitLab via the public DNS name (no in-VPC-only
#     routing needed; the bridge service in-cluster also calls GitLab's
#     public hostname for webhooks acknowledgment / API calls)
#   - Hostname `gitlab.<var.base_domain>` (e.g.
#     `gitlab.rhsummit.coderdemo.io`) — Route 53 A record in the same
#     hosted zone the cluster uses (cluster_zone in network.tf)
#
# TLS: Let's Encrypt via gitlab-ctl reconfigure (Omnibus handles
# renewal automatically through cron).
#
# IdP: only Keycloak (the demo realm's `gitlab` OIDC client). No
# GitHub OAuth on GitLab — GitLab is itself a new component; the
# dual-IdP-keeping-GitHub story is for OpenShift + Coder, not GitLab.
#
# Backup: daily EBS snapshot of the data volume via AWS Backup (or
# Lambda + cron). Not implemented in this TF for booth — manual
# snapshots are fine.

###############################################################################
# Hosted zone lookup (same one the cluster's Route 53 record uses).
# The zone is created by openshift-install at cluster-create time.
###############################################################################

data "aws_route53_zone" "cluster" {
  name = var.base_domain
}

###############################################################################
# Security group — HTTPS + SSH only. HTTP closed (Omnibus redirects
# 80 → 443 once Let's Encrypt is up, but only after the cert lands;
# we keep port 80 open during the cert renewal flow because
# gitlab-ctl's Let's Encrypt integration uses HTTP-01 by default).
###############################################################################

resource "aws_security_group" "gitlab" {
  name        = "${var.cluster_name}-gitlab"
  description = "GitLab CE on EC2 - HTTP from the in-cluster OpenShift router only; no public ingress"
  vpc_id      = var.vpc_id

  # HTTP from INSIDE THE VPC ONLY. TLS is terminated at the OpenShift edge
  # Route (cert-manager); the router pods (running on cluster nodes in this
  # VPC) reach GitLab's nginx over plain HTTP on :80. No public 80/443 — the
  # VM has no public IP and is not reachable from the internet. Both the
  # gitlab and registry vhosts are served off :80 (nginx routes by Host).
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTP - from OpenShift router (in-VPC) only; TLS terminates at the edge Route"
  }

  # SSH for operators. CLOSED BY DEFAULT (var.ssh_ingress_cidr = "") —
  # operators use SSM Session Manager (the instance carries the
  # AmazonSSMManagedInstanceCore profile below), so no public port 22 is
  # needed. Set var.ssh_ingress_cidr to a specific CIDR to re-open direct SSH.
  # Leaving it empty keeps Security Hub EC2.19 (CRITICAL) / EC2.18 (HIGH) green.
  dynamic "ingress" {
    for_each = var.ssh_ingress_cidr != "" ? [var.ssh_ingress_cidr] : []
    content {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
      description = "SSH - operator access (explicitly scoped via ssh_ingress_cidr)"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Egress unrestricted - packages, Keycloak via public route, webhook the bridge, etc."
  }

  tags = {
    Name = "${var.cluster_name}-gitlab"
  }
}

###############################################################################
# IAM instance profile — makes the VM AWS Systems Manager managed.
#
# Fixes Security Hub SSM.1, and in turn:
#   - SSM Session Manager replaces public SSH for operator access (so the
#     security group can keep port 22 closed — EC2.19 / EC2.18).
#   - SSM Patch Manager / Run Command can drive OS + gitlab-ce patching
#     reproducibly (the earlier "no patching mechanism" gap).
#   - Inspector agent-based (SSM) scanning activates for this instance.
# AmazonSSMManagedInstanceCore is the AWS-managed least-privilege policy for
# exactly this; the VM needs no other AWS API access.
###############################################################################

data "aws_iam_policy_document" "gitlab_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gitlab" {
  name               = "${var.cluster_name}-gitlab"
  assume_role_policy = data.aws_iam_policy_document.gitlab_assume.json

  tags = {
    Name = "${var.cluster_name}-gitlab"
  }
}

resource "aws_iam_role_policy_attachment" "gitlab_ssm" {
  role       = aws_iam_role.gitlab.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read-only access to the Keycloak demo-realm secret so cloud-init can fetch
# the `gitlab` OIDC client secret at boot (keeps it out of Terraform state and
# out of the rendered user-data). Scoped to the single secret ARN.
data "aws_iam_policy_document" "gitlab_keycloak_secret" {
  statement {
    sid       = "ReadKeycloakRealmSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.keycloak_secret_arn]
  }
}

resource "aws_iam_role_policy" "gitlab_keycloak_secret" {
  name   = "read-keycloak-realm-secret"
  role   = aws_iam_role.gitlab.name
  policy = data.aws_iam_policy_document.gitlab_keycloak_secret.json
}

resource "aws_iam_instance_profile" "gitlab" {
  name = "${var.cluster_name}-gitlab"
  role = aws_iam_role.gitlab.name
}

###############################################################################
# EBS data volume — /var/opt/gitlab lives here so we can blow away
# the VM and reattach the volume to recover state.
###############################################################################

resource "aws_ebs_volume" "gitlab_data" {
  availability_zone = "${var.aws_region}a"
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${var.cluster_name}-gitlab-data"
  }
}

###############################################################################
# cloud-init — installs gitlab-ce, Docker, gitlab-runner; wires OIDC.
###############################################################################

locals {
  gitlab_hostname   = "gitlab.${var.base_domain}"
  registry_hostname = "registry.gitlab.${var.base_domain}"
  keycloak_hostname = "keycloak.apps.cluster.${var.base_domain}"
  letsencrypt_email = "admin@${var.base_domain}"
}

resource "aws_instance" "gitlab" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_id
  private_ip             = var.private_ip
  vpc_security_group_ids = [aws_security_group.gitlab.id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = aws_iam_instance_profile.gitlab.name # SSM-managed (Session Manager + Patch Manager + Inspector agent)

  # Require IMDSv2 (token-backed) — blocks SSRF-style metadata theft and
  # satisfies Security Hub EC2.8.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  # No public IP — the VM sits on a private subnet and is reachable only via
  # the OpenShift edge Route (HTTPS) and SSM Session Manager (ops). Clears
  # Security Hub EC2.9. Egress (dnf, SSM, Keycloak OIDC discovery) goes out
  # through the VPC NAT gateway.
  associate_public_ip_address = false

  # Bigger root volume than default — GitLab Omnibus + Docker images
  # + Let's Encrypt + runners all share root.
  root_block_device {
    volume_size = 40
    volume_type = "gp3"
    encrypted   = true
  }

  # Cloud-init: install gitlab-ce + Docker + runner, wire OIDC.
  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    gitlab_hostname      = local.gitlab_hostname
    registry_hostname    = local.registry_hostname
    keycloak_hostname    = local.keycloak_hostname
    letsencrypt_email    = local.letsencrypt_email
    keycloak_secret_arn  = var.keycloak_secret_arn
    aws_region           = var.aws_region
    gitlab_root_password = var.gitlab_root_password
  })

  tags = {
    Name = "${var.cluster_name}-gitlab"
  }
}

# Attach the data volume AFTER the instance is up. cloud-init polls
# for /dev/nvme1n1 (NVMe-style mapping AL2023 uses) before mounting
# /var/opt/gitlab, so the install proceeds in the right order.
resource "aws_volume_attachment" "gitlab_data" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.gitlab_data.id
  instance_id  = aws_instance.gitlab.id
  force_detach = false
}

###############################################################################
# Route 53 -> OpenShift ingress load balancer.
#   gitlab.<base_domain> + registry.gitlab.<base_domain> now resolve to the
#   cluster's router/ingress LB (the GitLab VM has no public IP). TLS + host
#   routing happen at the OpenShift edge Routes (manifests/gitlab-ingress/).
#   Set ingress_lb_hostname to the router LB DNS name:
#     oc -n openshift-ingress get svc router-default \
#       -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
#   Left empty => no records managed here (lets the blue/green cutover flip DNS
#   out-of-band, or external-dns manage it).
###############################################################################

resource "aws_route53_record" "gitlab" {
  count   = var.ingress_lb_hostname != "" ? 1 : 0
  zone_id = data.aws_route53_zone.cluster.zone_id
  name    = local.gitlab_hostname
  type    = "CNAME"
  ttl     = 60
  records = [var.ingress_lb_hostname]
}

resource "aws_route53_record" "registry" {
  count   = var.ingress_lb_hostname != "" ? 1 : 0
  zone_id = data.aws_route53_zone.cluster.zone_id
  name    = local.registry_hostname
  type    = "CNAME"
  ttl     = 60
  records = [var.ingress_lb_hostname]
}
