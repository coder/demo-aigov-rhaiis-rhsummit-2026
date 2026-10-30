###############################################################################
# Keycloak demo-realm secrets — AWS Secrets Manager + IRSA
#
# Single source of truth for the Keycloak `demo` realm credentials:
#   - 3 persona passwords (alice, bob, demoadm)
#   - 4 OIDC client secrets (coder, gitlab, openshift, grafana)
#
# All values are GENERATED here (random_password) and stored as ONE JSON
# secret in AWS Secrets Manager in the deploy account/region. Nothing is
# committed to git. In-cluster consumers read them via the External Secrets
# Operator (ESO), which assumes the IAM role below through the cluster's
# STS/OIDC provider (IRSA). The GitLab VM reads its client secret at boot via
# its instance profile (see terraform/gitlab/).
#
# Rotation: `terraform apply -replace=random_password.kc_user[\"demoadm\"]`
# (etc.) mints a new value, updates the SM version; ESO re-syncs within its
# refresh interval and the realm re-imports on the next Keycloak app sync.
###############################################################################

locals {
  keycloak_realm_secret_name = "rhsummit/keycloak/demo-realm"

  kc_user_names   = ["alice", "bob", "demoadm"]
  kc_client_names = ["coder", "gitlab", "openshift", "grafana"]
}

# Persona passwords — 24 chars, letters+digits+a safe special set. We avoid
# quote/slash/backslash chars that complicate shell/YAML/JSON round-tripping
# through the realm render job.
resource "random_password" "kc_user" {
  for_each         = toset(local.kc_user_names)
  length           = 24
  special          = true
  override_special = "!#%*-_=+:?"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

# OIDC client secrets — 40 chars, alphanumeric only. OAuth client secrets flow
# through URL-encoded form posts and HTTP headers across four different
# consumers; keeping them alnum avoids any encoding ambiguity.
resource "random_password" "kc_client" {
  for_each = toset(local.kc_client_names)
  length   = 40
  special  = false
}

resource "aws_secretsmanager_secret" "keycloak_demo_realm" {
  name        = local.keycloak_realm_secret_name
  description = "Keycloak demo-realm persona passwords + OIDC client secrets (RH Summit 2026). Managed by Terraform; consumed in-cluster via External Secrets Operator (IRSA)."

  # Demo reset-friendliness: no soft-delete recovery window so a destroy/apply
  # cycle can immediately recreate the same secret name.
  recovery_window_in_days = 0

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "keycloak_demo_realm" {
  secret_id = aws_secretsmanager_secret.keycloak_demo_realm.id
  secret_string = jsonencode({
    alice_password          = random_password.kc_user["alice"].result
    bob_password            = random_password.kc_user["bob"].result
    demoadm_password        = random_password.kc_user["demoadm"].result
    coder_client_secret     = random_password.kc_client["coder"].result
    gitlab_client_secret    = random_password.kc_client["gitlab"].result
    openshift_client_secret = random_password.kc_client["openshift"].result
    grafana_client_secret   = random_password.kc_client["grafana"].result
  })
}

###############################################################################
# IRSA role for the External Secrets Operator
#
# ESO's ClusterSecretStore references a ServiceAccount (external-secrets/
# eso-aws-sm); that SA assumes this role via sts:AssumeRoleWithWebIdentity
# through the cluster OIDC provider. Scoped read-only to the one secret.
###############################################################################

resource "aws_iam_role" "external_secrets" {
  name = "${var.cluster_name}-external-secrets"
  path = "/demo/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowExternalSecretsSA"
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:external-secrets:eso-aws-sm"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid    = "ReadKeycloakRealmSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [aws_secretsmanager_secret.keycloak_demo_realm.arn]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-keycloak-realm-secret"
  role   = aws_iam_role.external_secrets.name
  policy = data.aws_iam_policy_document.external_secrets.json
}
