###############################################################################
# OpenShift IPI install + supporting AWS infra
#
# Flow:
#   1. Read pull secret + ssh public key
#   2. Create scoped IAM roles (cert-manager Route 53; Coder -> Bedrock)
#   3. Render install-config.yaml from template into <install_dir>
#   4. Run `openshift-install create cluster --dir=<install_dir>` (~30-45 min)
#   5. Apply RH-supported + community operator subscriptions (OpenShift
#      GitOps + cert-manager + CloudNativePG)
#   6. Bootstrap cluster-side config the apps expect to find:
#        - sts:AssumeRole permissions on OCP node roles
#        - ClusterIssuers with IAM role ARN (cert-manager -> Route 53)
#        - bedrock-aws-config ConfigMap (Coder -> Bedrock via AssumeRole)
#        - redhat-pull-secret    (RHAIIS image pull from registry.redhat.io)
#   7. Apply Argo CD root Application (app-of-apps bootstrap). CNPG operator
#      then stands up an in-cluster Postgres Cluster that auto-generates the
#      `coder-app` Secret consumed by the Coder Helm chart.
#
# `terraform destroy` runs `openshift-install destroy cluster` first, then
# tears down the IAM roles. The cluster install dir is preserved on disk
# for debugging; wipe it manually after destroy if you need a clean slate.
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
# (per PR coder/coder#24397 in v2.33-rc.3). The bootstrap step creates a
# ConfigMap with an AWS shared-config that chains AssumeRole into this
# role via EC2 IMDS base credentials.
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
# cert-manager uses ambient credentials (EC2 IMDS on the node) to
# AssumeRole into the cert-manager IAM role, then creates/removes
# `_acme-challenge.<domain>` TXT records for wildcard cert issuance.
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
      echo "Running openshift-install create cluster (this takes 30-45 min)..."
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
# Bootstrap operators + IRSA trust chain + Argo CD root Application
#
# This step runs immediately after the cluster is up. It:
#   1. Installs OLM operator subscriptions (GitOps, cert-manager, CNPG)
#   2. Discovers the IPI-created node IAM roles and adds sts:AssumeRole
#      permissions so pods can chain-assume into the service roles
#   3. Enables ambient credentials on cert-manager and applies the
#      ClusterIssuers with the cert-manager IAM role ARN
#   4. Creates a ConfigMap with AWS shared-config for Coder Bedrock
#   5. Applies the Argo CD root Application (app-of-apps)
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
%{ if var.aws_profile != null ~}
      export AWS_PROFILE="${var.aws_profile}"
%{ endif ~}
      export AWS_REGION="${var.aws_region}"

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

      # ── IRSA trust chain ──────────────────────────────────────────
      # Discover the IPI-created node IAM roles and grant them
      # permission to AssumeRole into our service roles. This lets pods
      # on OCP nodes use EC2 IMDS base credentials to chain-assume
      # into scoped roles (cert-manager -> Route 53, Coder -> Bedrock).

      echo "==> Discovering OCP infrastructure ID for node IAM role names..."
      INFRA_ID=$(${var.oc_binary} get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
      MASTER_ROLE="$${INFRA_ID}-master-role"
      WORKER_ROLE="$${INFRA_ID}-worker-role"
      echo "    Infrastructure ID: $${INFRA_ID}"
      echo "    Master role: $${MASTER_ROLE}"
      echo "    Worker role: $${WORKER_ROLE}"

      echo "==> Adding sts:AssumeRole permissions to OCP node roles..."
      ASSUME_POLICY='{"Version":"2012-10-17","Statement":[{"Sid":"AssumeDemoServiceRoles","Effect":"Allow","Action":"sts:AssumeRole","Resource":["${aws_iam_role.cert_manager.arn}","${aws_iam_role.coder_bedrock.arn}"]}]}'

      aws iam put-role-policy \
        --role-name "$${MASTER_ROLE}" \
        --policy-name "assume-demo-service-roles" \
        --policy-document "$${ASSUME_POLICY}"

      aws iam put-role-policy \
        --role-name "$${WORKER_ROLE}" \
        --policy-name "assume-demo-service-roles" \
        --policy-document "$${ASSUME_POLICY}"

      # ── cert-manager ambient credentials ──────────────────────────
      # Enable ambient credential support so the controller can use
      # EC2 IMDS to AssumeRole. On cert-manager v1.14+ (shipped by the
      # OCP operator) this is the default, but we set it explicitly to
      # be safe across operator upgrades.

      echo "==> Enabling ambient credentials on cert-manager controller..."
      ${var.oc_binary} patch certmanager cluster --type=merge \
        -p '{"spec":{"controllerConfig":{"overrideArgs":["--issuer-ambient-credentials=true","--cluster-issuer-ambient-credentials=true"]}}}' \
        2>/dev/null || echo "    Note: CertManager CR not yet available; ambient creds are default on cert-manager v1.14+"

      echo "==> Applying ClusterIssuers with IAM role for Route 53 DNS-01..."
      cat <<'ISSUER_EOF' | sed "s|CERT_MANAGER_ROLE_ARN|${aws_iam_role.cert_manager.arn}|g; s|OWNER_EMAIL|${var.owner_email}|g; s|AWS_REGION_VALUE|${var.aws_region}|g" | ${var.oc_binary} apply --server-side -f -
      apiVersion: cert-manager.io/v1
      kind: ClusterIssuer
      metadata:
        name: letsencrypt-prod
      spec:
        acme:
          server: https://acme-v02.api.letsencrypt.org/directory
          email: OWNER_EMAIL
          privateKeySecretRef:
            name: letsencrypt-prod-account-key
          solvers:
            - dns01:
                route53:
                  region: AWS_REGION_VALUE
                  role: CERT_MANAGER_ROLE_ARN
      ---
      apiVersion: cert-manager.io/v1
      kind: ClusterIssuer
      metadata:
        name: letsencrypt-staging
      spec:
        acme:
          server: https://acme-staging-v02.api.letsencrypt.org/directory
          email: OWNER_EMAIL
          privateKeySecretRef:
            name: letsencrypt-staging-account-key
          solvers:
            - dns01:
                route53:
                  region: AWS_REGION_VALUE
                  role: CERT_MANAGER_ROLE_ARN
      ISSUER_EOF

      # ── Coder namespace + Bedrock AWS config ──────────────────────

      echo "==> Creating coder namespace if missing..."
      ${var.oc_binary} create namespace coder --dry-run=client -o yaml | ${var.oc_binary} apply -f -

      echo "==> Creating Bedrock AWS config ConfigMap (role-based credential chain via IMDS)..."
      cat <<CONFIGMAP_EOF | ${var.oc_binary} apply -f -
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: bedrock-aws-config
        namespace: coder
        labels:
          app.kubernetes.io/part-of: coder-aigov-demo
          app.kubernetes.io/component: aws-credentials
      data:
        config: |
          [default]
          role_arn = ${aws_iam_role.coder_bedrock.arn}
          credential_source = Ec2InstanceMetadata
          region = ${var.aws_region}
      CONFIGMAP_EOF

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
