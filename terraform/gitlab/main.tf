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
  description = "GitLab CE on EC2 — HTTPS for booth/cluster, SSH for ops"
  vpc_id      = var.vpc_id

  # HTTPS — booth laptops + in-cluster webhook callbacks
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS — booth + cluster"
  }

  # HTTP — needed transiently for Let's Encrypt HTTP-01 ACME challenge.
  # Once the cert is in place gitlab-ctl auto-redirects to HTTPS.
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP — Let's Encrypt HTTP-01 challenge + initial setup"
  }

  # SSH for operators. Default is wide-open; narrow in tfvars.
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
    description = "SSH — operator access (default open; narrow in tfvars)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Egress unrestricted — GitLab needs to fetch packages, hit Keycloak (in cluster public route), webhook the bridge, etc."
  }

  tags = {
    Name = "${var.cluster_name}-gitlab"
  }
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
  keycloak_hostname = "keycloak.apps.cluster.${var.base_domain}"
  letsencrypt_email = "admin@${var.base_domain}"
}

resource "aws_instance" "gitlab" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [aws_security_group.gitlab.id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = null # no IAM role for now; GitLab doesn't need AWS API access

  # Bigger root volume than default — GitLab Omnibus + Docker images
  # + Let's Encrypt + runners all share root.
  root_block_device {
    volume_size = 40
    volume_type = "gp3"
    encrypted   = true
  }

  # Cloud-init: install gitlab-ce + Docker + runner, wire OIDC.
  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    gitlab_hostname     = local.gitlab_hostname
    keycloak_hostname   = local.keycloak_hostname
    letsencrypt_email   = local.letsencrypt_email
    oidc_client_secret  = var.keycloak_oidc_client_secret
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
# Route 53 A record — `gitlab.<base_domain>` → EC2 public IP
###############################################################################

resource "aws_route53_record" "gitlab" {
  zone_id = data.aws_route53_zone.cluster.zone_id
  name    = local.gitlab_hostname
  type    = "A"
  ttl     = 60
  records = [aws_instance.gitlab.public_ip]
}
