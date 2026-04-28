###############################################################################
# OpenShift IPI install + supporting AWS infra
#
# Flow:
#   1. Read pull secret + ssh public key
#   2. Create dedicated IAM users (cert-manager Route 53; Coder → Bedrock)
#   3. Render install-config.yaml from template into <install_dir>. The
#      template emits TWO compute pools: (a) `worker` with replicas 0 —
#      placeholder, (b) `gpu` with `gpu_count` replicas of `gpu_instance_type`,
#      pinned to one AZ. The 3 control-plane nodes are sized to be
#      schedulable for general workloads (compact converged shape).
#   4. Run `openshift-install create cluster --dir=<install_dir>` (~30–45 min)
#   5. Apply RH-supported + community + certified operator subscriptions:
#      OpenShift GitOps, cert-manager, CloudNativePG, NFD, NVIDIA GPU operator
#   6. Bootstrap a few Kubernetes Secrets the cluster apps expect to find:
#        - route53-credentials   (cert-manager → Route 53 DNS-01)
#        - bedrock-credentials   (Coder server / AI Gateway → Bedrock)
#        - redhat-pull-secret    (RHAIIS image pull from registry.redhat.io)
#   7. Apply Argo CD root Application (app-of-apps bootstrap). CNPG operator
#      stands up an in-cluster Postgres Cluster (auto-generates the
#      `coder-app` Secret); the gpu-stack Argo app rolls NVIDIA drivers
#      onto the GPU node so RHAIIS can schedule there.
#
# `terraform destroy` runs `openshift-install destroy cluster` first, then
# tears down the AWS IAM users. The cluster install dir is preserved on disk
# for debugging — wipe it manually after destroy if you need a clean slate.
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
# IAM user for Coder server / AI Gateway → AWS Bedrock
#
# AI Gateway picks up ambient AWS credentials from env vars on the Coder
# server pod (per PR coder/coder#24397 in v2.33-rc.3). The bootstrap step
# materializes these creds as Kubernetes Secret `bedrock-credentials` in
# the `coder` namespace; the Helm values mount AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY from that Secret as env vars. AWS_REGION is set
# to the cluster region.
#
# NOTE: AWS retired the per-model "Manage model access" page in late 2025.
# Serverless models on Bedrock now auto-enable on first invocation by any
# IAM principal in the account. First-time Anthropic users are prompted
# for a one-page use-case form on first open/invoke — fill it in once,
# approval is typically minutes, and the entire account is unblocked.
###############################################################################

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

resource "aws_iam_user" "coder_bedrock" {
  name = "${var.cluster_name}-coder-bedrock"
  path = "/demo/"
}

resource "aws_iam_user_policy" "coder_bedrock" {
  name   = "bedrock-invoke"
  user   = aws_iam_user.coder_bedrock.name
  policy = data.aws_iam_policy_document.coder_bedrock.json
}

resource "aws_iam_access_key" "coder_bedrock" {
  user = aws_iam_user.coder_bedrock.name
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
    sid       = "GetChange"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }
  statement {
    sid    = "ChangeResourceRecordSets"
    effect = "Allow"
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
    gpu_count                   = var.gpu_count
    gpu_instance_type           = var.gpu_instance_type
    gpu_zone                    = local.vpc_azs[var.gpu_zone_index]
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
    install_dir        = var.install_dir
    install_binary     = var.openshift_install_binary
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
# Bootstrap operators + cluster Secrets + Argo CD root Application
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

      echo "==> Waiting for NFD CRDs (NodeFeatureDiscovery)..."
      for i in $(seq 1 60); do
        if ${var.oc_binary} get crd nodefeaturediscoveries.nfd.openshift.io 2>/dev/null | grep -q nodefeaturediscoveries; then
          break
        fi
        echo "    ...waiting for NFD CRDs ($i/60)"
        sleep 10
      done

      echo "==> Waiting for NVIDIA GPU operator CRDs (ClusterPolicy)..."
      for i in $(seq 1 60); do
        if ${var.oc_binary} get crd clusterpolicies.nvidia.com 2>/dev/null | grep -q clusterpolicies; then
          break
        fi
        echo "    ...waiting for NVIDIA GPU operator CRDs ($i/60)"
        sleep 10
      done

      echo "==> Creating Route 53 credentials Secret in cert-manager namespace..."
      ${var.oc_binary} create secret generic route53-credentials \
        --namespace=cert-manager \
        --from-literal=access-key-id='${aws_iam_access_key.cert_manager.id}' \
        --from-literal=secret-access-key='${aws_iam_access_key.cert_manager.secret}' \
        --dry-run=client -o yaml | ${var.oc_binary} apply -f -

      echo "==> Creating coder namespace if missing..."
      ${var.oc_binary} create namespace coder --dry-run=client -o yaml | ${var.oc_binary} apply -f -

      echo "==> Creating Bedrock credentials Secret in coder namespace (AI Gateway picks these up via ambient AWS env vars)..."
      ${var.oc_binary} create secret generic bedrock-credentials \
        --namespace=coder \
        --from-literal=aws-access-key-id='${aws_iam_access_key.coder_bedrock.id}' \
        --from-literal=aws-secret-access-key='${aws_iam_access_key.coder_bedrock.secret}' \
        --from-literal=aws-region='${var.aws_region}' \
        --dry-run=client -o yaml | ${var.oc_binary} apply -f -

      echo "==> Creating ocp-ai namespace if missing..."
      ${var.oc_binary} create namespace ocp-ai --dry-run=client -o yaml | ${var.oc_binary} apply -f -

      echo "==> Creating redhat-pull-secret in ocp-ai namespace (consumed by RHAIIS Deployment)..."
      ${var.oc_binary} create secret docker-registry redhat-pull-secret \
        --namespace=ocp-ai \
        --from-file=.dockerconfigjson=${pathexpand(var.pull_secret_path)} \
        --dry-run=client -o yaml | ${var.oc_binary} apply -f -

      echo "==> Bootstrapping Argo CD root Application (app-of-apps)..."
      ${var.oc_binary} apply -f ${path.module}/../gitops/bootstrap/root-app.yaml

      echo "==> GitOps bootstrap complete. Watch sync with:"
      echo "       oc get applications -n openshift-gitops -w"
    EOT
  }
}
