###############################################################################
# OpenShift IPI install with STS (manual credentials mode) + supporting infra
#
# Flow:
#   1. Read pull secret + ssh public key
#   2. Create scoped IAM roles for workloads (cert-manager, Coder Bedrock)
#   3. Render install-config.yaml (credentialsMode: Manual) into <install_dir>
#   4. Run `openshift-install create manifests`
#   5. Extract ccoctl from the release image, run `ccoctl aws create-all` to
#      create the OIDC provider (S3 bucket), signing keys, and platform IAM
#      roles. Copy generated manifests + TLS keys into the install dir.
#   6. Run `openshift-install create cluster --dir=<install_dir>` (~30-45 min).
#      The installer uses the pre-created STS manifests. The pod identity
#      webhook is included automatically with STS mode.
#   7. Apply RH-supported + community operator subscriptions (OpenShift
#      GitOps + cert-manager + CloudNativePG)
#   8. Annotate ServiceAccounts with IAM role ARNs so the pod identity
#      webhook injects credentials (projected SA tokens + env vars):
#        - cert-manager SA -> Route 53 IAM role
#        - coder SA        -> Bedrock IAM role
#   9. Apply Argo CD root Application (app-of-apps bootstrap).
#
# `terraform destroy` runs `openshift-install destroy cluster` first, then
# `ccoctl aws delete` to clean up the OIDC provider + platform IAM roles,
# then tears down the workload IAM roles + VPC.
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
# IAM policy documents (consumed by roles in irsa.tf)
###############################################################################

# Bedrock invoke permissions for Coder AI Gateway.
#
# AI Gateway picks up ambient AWS credentials from the Coder server pod
# (per PR coder/coder#24397 in v2.33-rc.3). With STS mode, the pod
# identity webhook injects projected SA tokens that the SDK exchanges
# for temporary Bedrock-scoped credentials via sts:AssumeRoleWithWebIdentity.
#
# IMPORTANT: Bedrock model access is granted per-account, per-region,
# per-model via a one-time AWS console step. After this Terraform applies,
# go to the Bedrock console for ${var.aws_region} and request access to
# the Anthropic models you'll use for the demo (Claude Sonnet 4.x at
# minimum). Approval is typically instant for Anthropic on Bedrock.

data "aws_iam_policy_document" "coder_bedrock" {
  statement {
    sid    = "BedrockInvoke"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:Converse",
      "bedrock:ConverseStream",
      "bedrock:ListFoundationModels",
      "bedrock:GetFoundationModel",
      "bedrock:ListInferenceProfiles",
      "bedrock:GetInferenceProfile",
    ]
    # Demo: allow against all foundation models. Production: scope to the
    # specific model and inference-profile ARNs you have access to.
    resources = ["*"]
  }
}

# Route 53 permissions for cert-manager DNS-01 ACME challenges.
#
# Permissions follow the cert-manager docs:
# https://cert-manager.io/docs/configuration/acme/dns01/route53/

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
# STS setup: create manifests, run ccoctl, prepare install dir
#
# This must run BEFORE `openshift-install create cluster` because the
# installer needs the ccoctl-generated credential manifests and signing
# keys in the install directory.
#
# Steps:
#   1. `openshift-install create manifests` (consumes install-config.yaml)
#   2. Extract ccoctl binary from the release image
#   3. `ccoctl aws create-all` (creates S3 OIDC bucket, IAM OIDC provider,
#      platform IAM roles, signing keys)
#   4. Copy ccoctl output manifests + TLS keys into install dir
###############################################################################

resource "null_resource" "sts_setup" {
  depends_on = [local_sensitive_file.install_config]

  triggers = {
    install_dir    = var.install_dir
    cluster_name   = var.cluster_name
    aws_region     = var.aws_region
    aws_profile    = var.aws_profile != null ? var.aws_profile : ""
    install_binary = var.openshift_install_binary
    install_config_md5 = local_sensitive_file.install_config.content_md5
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
%{ if var.aws_profile != null ~}
      export AWS_PROFILE="${var.aws_profile}"
%{ endif ~}
      export AWS_REGION="${var.aws_region}"
      INSTALL_DIR="${var.install_dir}"
      PULL_SECRET="${pathexpand(var.pull_secret_path)}"

      echo "==> Creating OpenShift manifests (consumes install-config.yaml)..."
      ${var.openshift_install_binary} create manifests --dir="$INSTALL_DIR"

      echo "==> Extracting ccoctl from release image..."
      RELEASE_IMAGE=$(${var.openshift_install_binary} version | awk '/release image/ {print $3}')
      CCO_IMAGE=$(${var.oc_binary} adm release info --image-for='cloud-credential-operator' "$RELEASE_IMAGE" -a "$PULL_SECRET")
      ${var.oc_binary} image extract "$CCO_IMAGE" --file="/usr/bin/ccoctl" -a "$PULL_SECRET"
      chmod +x ./ccoctl

      echo "==> Extracting CredentialsRequests from release image..."
      mkdir -p "$INSTALL_DIR/cred-reqs"
      ${var.oc_binary} adm release extract \
        --credentials-requests --cloud=aws \
        --to="$INSTALL_DIR/cred-reqs" \
        --from="$RELEASE_IMAGE" -a "$PULL_SECRET"

      echo "==> Running ccoctl aws create-all (OIDC provider + platform IAM roles)..."
      ./ccoctl aws create-all \
        --name="${var.cluster_name}" \
        --region="${var.aws_region}" \
        --credentials-requests-dir="$INSTALL_DIR/cred-reqs" \
        --output-dir="$INSTALL_DIR/ccoctl-output"

      echo "==> Copying ccoctl manifests + TLS keys into install dir..."
      cp "$INSTALL_DIR/ccoctl-output/manifests/"* "$INSTALL_DIR/manifests/"
      cp -a "$INSTALL_DIR/ccoctl-output/tls" "$INSTALL_DIR/tls/"

      echo "==> STS setup complete. Ready for openshift-install create cluster."
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -euo pipefail
%{ if self.triggers.aws_profile != "" ~}
      export AWS_PROFILE="${self.triggers.aws_profile}"
%{ endif ~}
      export AWS_REGION="${self.triggers.aws_region}"

      echo "==> Cleaning up ccoctl-created AWS resources (OIDC provider + platform IAM roles)..."
      if [ -x ./ccoctl ]; then
        ./ccoctl aws delete \
          --name="${self.triggers.cluster_name}" \
          --region="${self.triggers.aws_region}" || true
      else
        echo "    ccoctl binary not found; skipping OIDC cleanup."
        echo "    If the S3 bucket ${self.triggers.cluster_name}-oidc still exists, delete it manually."
      fi
    EOT
  }
}

###############################################################################
# Run openshift-install
###############################################################################

resource "null_resource" "openshift_install" {
  depends_on = [null_resource.sts_setup]

  triggers = {
    install_dir    = var.install_dir
    install_binary = var.openshift_install_binary
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      echo "Running openshift-install create cluster (this takes 30-45 min)..."
      echo "The installer will use the pre-created STS manifests from ccoctl."
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
# Bootstrap operators + IRSA ServiceAccount annotations + Argo CD root app
#
# This step runs immediately after the cluster is up. It:
#   1. Installs OLM operator subscriptions (GitOps, cert-manager, CNPG)
#   2. Annotates ServiceAccounts with IAM role ARNs so the pod identity
#      webhook (included with STS mode) injects projected SA tokens
#   3. Applies the Argo CD root Application (app-of-apps)
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

      echo "==> Applying operator subscriptions (OpenShift GitOps + cert-manager + CloudNativePG)..."
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

      echo "==> Waiting for CloudNativePG CRDs (Cluster) to be installed..."
      for i in $(seq 1 60); do
        if ${var.oc_binary} get crd clusters.postgresql.cnpg.io 2>/dev/null | grep -q clusters; then
          break
        fi
        echo "    ...waiting for CNPG CRDs ($i/60)"
        sleep 10
      done

      # ── IRSA ServiceAccount annotations ───────────────────────────
      # The pod identity webhook (installed with STS mode) watches for
      # the eks.amazonaws.com/role-arn annotation on ServiceAccounts.
      # When a pod uses an annotated SA, the webhook mutates the pod to
      # inject AWS_ROLE_ARN, AWS_WEB_IDENTITY_TOKEN_FILE, and a
      # projected SA token volume. The AWS SDK picks these up to call
      # sts:AssumeRoleWithWebIdentity for temporary credentials.

      echo "==> Waiting for cert-manager ServiceAccount to be created by the operator..."
      for i in $(seq 1 30); do
        if ${var.oc_binary} get serviceaccount cert-manager -n cert-manager 2>/dev/null; then
          break
        fi
        echo "    ...waiting for cert-manager SA ($i/30)"
        sleep 10
      done

      echo "==> Annotating cert-manager SA with Route 53 IAM role ARN..."
      ${var.oc_binary} annotate serviceaccount cert-manager \
        -n cert-manager \
        eks.amazonaws.com/role-arn="${aws_iam_role.cert_manager.arn}" \
        --overwrite

      echo "==> Restarting cert-manager to pick up IRSA annotation..."
      ${var.oc_binary} rollout restart -n cert-manager deployment/cert-manager 2>/dev/null || \
        echo "    Note: cert-manager deployment not yet ready; the operator will reconcile."

      echo "==> Creating coder namespace if missing..."
      ${var.oc_binary} create namespace coder --dry-run=client -o yaml | ${var.oc_binary} apply -f -

      echo "==> Pre-creating coder ServiceAccount with Bedrock IAM role annotation..."
      cat <<SA_EOF | ${var.oc_binary} apply -f -
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: coder
        namespace: coder
        annotations:
          eks.amazonaws.com/role-arn: "${aws_iam_role.coder_bedrock.arn}"
      SA_EOF

      # ── RHAIIS pull secret ────────────────────────────────────────

      echo "==> Creating ocp-ai namespace if missing..."
      ${var.oc_binary} create namespace ocp-ai --dry-run=client -o yaml | ${var.oc_binary} apply -f -

      echo "==> Creating redhat-pull-secret in ocp-ai namespace (consumed by RHAIIS Deployment)..."
      ${var.oc_binary} create secret docker-registry redhat-pull-secret \
        --namespace=ocp-ai \
        --from-file=.dockerconfigjson=${pathexpand(var.pull_secret_path)} \
        --dry-run=client -o yaml | ${var.oc_binary} apply -f -

      # ── Argo CD root Application ──────────────────────────────────

      echo "==> Bootstrapping Argo CD root Application (app-of-apps)..."
      ${var.oc_binary} apply -f ${path.module}/../gitops/bootstrap/root-app.yaml

      echo "==> GitOps bootstrap complete. Watch sync with:"
      echo "       oc get applications -n openshift-gitops -w"
    EOT
  }
}
