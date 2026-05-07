# AWS credentials — what's needed, where, and why

> **STS mode with IRSA.** The cluster runs in `credentialsMode: Manual` with
> AWS STS. All in-cluster credentials are short-lived tokens issued via
> `sts:AssumeRoleWithWebIdentity` through an OIDC provider. No static IAM
> user access keys exist anywhere in this deployment.

Three personas hold AWS credentials in this demo:

1. **You** — the human running Terraform and the scripts in `scripts/`.
2. **The cluster** — IAM roles assumed via OIDC-federated service account tokens (STS), plus the IPI installer's instance profiles for the OCP nodes.
3. **AWS Bedrock** — a one-time per-region, per-model human approval in the AWS console, gated by your account.

GitHub Actions has **no AWS creds** after the GHCR migration. CI pushes use `GITHUB_TOKEN`.

---

## Build-time — running Terraform / scripts from your laptop

| Cred | Source | Consumed by | Scope |
|---|---|---|---|
| **OpenShift Deployment profile** in `~/.aws/credentials` (or `AWS_PROFILE_OCP_DEPLOY` in `.env`) | You — pre-existing in your shell | `terraform apply` (AWS provider + `ccoctl` + `openshift-install`); every `aws` CLI call in `scripts/*` | Account-admin in the OCP deployment AWS account — effectively required for OCP IPI |
| **R53 Parent profile** (optional) | You — separate `~/.aws/credentials` profile in the parent account | `scripts/bootstrap-r53-delegation.sh --parent-profile` only | `route53:ChangeResourceRecordSets` on the parent (`coderdemo.io`) hosted zone. |
| **GitHub PAT** (`gh auth login`) | You | `gh repo create`, `gh secret set`, repo workflows | Repo-scoped for `coder/*`. Not AWS. |

---

## Operation-time — cluster running (STS mode)

### How IRSA works on this cluster

1. **Before install**, the `ccoctl` tool (extracted from the OCP release image) creates:
   - An S3 bucket (`<cluster_name>-oidc`) with OIDC discovery documents and JWKS
   - An IAM OIDC identity provider pointing to that S3 bucket
   - Platform IAM roles for OCP components (image-registry, machine-api, CSI, etc.)
   - A signing key pair for ServiceAccount tokens

2. **During install**, the cluster is configured with `credentialsMode: Manual`. The API server signs ServiceAccount tokens with the signing key. AWS IAM trusts these tokens because the OIDC provider validates them against the public keys in the S3 bucket.

3. **The pod identity webhook** (included automatically with STS mode) watches for ServiceAccounts annotated with `eks.amazonaws.com/role-arn`. When a pod uses an annotated SA, the webhook mutates the pod to inject:
   - `AWS_ROLE_ARN` environment variable
   - `AWS_WEB_IDENTITY_TOKEN_FILE` environment variable
   - A projected ServiceAccount token volume (audience: `sts.amazonaws.com`, refreshed hourly)

4. **The AWS SDK** in the pod reads these env vars, sends the token to `sts:AssumeRoleWithWebIdentity`, and receives temporary credentials scoped to the IAM role. Tokens refresh every hour automatically.

### Workload IAM roles

| IAM role | Created by | Permissions | ServiceAccount | How auth works |
|---|---|---|---|---|
| `<cluster>-cert-manager-route53` | `terraform/irsa.tf` | Route 53: `GetChange`, `ChangeResourceRecordSets`, `ListResourceRecordSets`, `ListHostedZonesByName` | `cert-manager:cert-manager` | Pod identity webhook injects token; cert-manager uses ambient AWS SDK credentials |
| `<cluster>-coder-bedrock` | `terraform/irsa.tf` | Bedrock: `InvokeModel*`, `Converse*`, `List*`, `Get*` on `*` | `coder:coder` | Pod identity webhook injects token; AI Gateway uses ambient AWS SDK credentials |
| Platform roles (6+) | `ccoctl aws create-all` | EC2, EBS CSI, image registry, machine API, ingress, CCO | Various `openshift-*` SAs | Same webhook mechanism |

### Trust policy structure

Each role's trust policy uses OIDC federation scoped to a specific ServiceAccount:

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::<account>:oidc-provider/<cluster>-oidc.s3.<region>.amazonaws.com"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "<cluster>-oidc.s3.<region>.amazonaws.com:sub": "system:serviceaccount:<namespace>:<sa-name>"
    }
  }
}
```

Only the specific ServiceAccount in the specific namespace can assume the role. Other pods (even on the same node) cannot.

---

## AWS Bedrock model access — first-invoke auto-enable + Anthropic use-case form

AWS retired the per-model "Manage model access" console page in late 2025. Serverless foundation models on Bedrock are now **automatically enabled in your account when first invoked** — no manual activation step.

Two caveats remain:

1. **First-time Anthropic users** (no prior Anthropic-on-Bedrock invocation in this account) are prompted for a one-page use-case form when they open Claude in the Model catalog or first invoke it. Approval is typically minutes; the form is `https://${AWS_REGION}.console.aws.amazon.com/bedrock/home?region=${AWS_REGION}#/foundation-models` → click into the model.
2. **AWS Marketplace models** (NOT Anthropic-direct, but third-party catalog entries) require an admin with Marketplace permissions to invoke the model once before account-wide access kicks in.

Practically, our demo only needs Anthropic Claude (Sonnet/Opus tier) for the cloud provider behind AI Gateway. Smoke-test the activation with `aws bedrock-runtime invoke-model --model-id anthropic.claude-sonnet-4-...` once before the booth — if it returns content, you're set; if it errors with `AccessDeniedException` and a use-case-form pointer, fill the form and retry.

After the first successful invocation, the `coder-bedrock` IAM role (assumed via IRSA) works without any further console interaction.

---

## Lifecycle

- **IAM roles** (workload): managed by Terraform. `terraform destroy` deletes them.
- **OIDC provider + platform roles**: managed by `ccoctl`. The Terraform destroy provisioner runs `ccoctl aws delete` to clean them up.
- **No credential rotation needed.** STS tokens auto-expire (1 hour) and are refreshed by the AWS SDK and the projected token volume.
- **OCP deploy profile rotation** is on you / your AWS Org policy.

---

## What's stored where on disk

| Where | What | Sensitivity |
|---|---|---|
| `~/.aws/credentials` | OCP deploy + R53 parent profile (yours) | High — your laptop |
| `terraform/.terraform.tfstate` | IAM role ARNs, OIDC provider ARN (no secrets) | Low |
| `${install_dir}/auth/kubeconfig` | Cluster kubeadmin kubeconfig | High |
| `${install_dir}/auth/kubeadmin-password` | Initial kubeadmin password | High |
| `${install_dir}/ccoctl-output/tls/` | SA signing private key | High — used to sign tokens |
| `~/.openshift/pull-secret.json` | RH partner pull-secret (yours) | High |

---

## Quick reference

| Question | Answer |
|---|---|
| Who needs AWS creds to run `terraform apply`? | You — ocp-deploy profile, account-admin level. |
| Who needs AWS creds in GitHub Actions? | Nobody. GHCR uses `GITHUB_TOKEN`. |
| What can the cert-manager role do? | Edit Route 53 records in the cluster's `base_domain` zone. Nothing else. |
| What can the coder-bedrock role do? | Invoke Bedrock models (any). Nothing else. |
| How does AI Gateway find Bedrock creds? | Pod identity webhook injects `AWS_ROLE_ARN` + token file from SA annotation. AWS SDK handles the rest. |
| Can any pod assume any role? | No. OIDC trust is scoped to `system:serviceaccount:<ns>:<sa>`. Only the specific SA can assume its role. |
| Where does the workspace get AWS creds? | It doesn't. Workspaces talk to AI Gateway only; AI Gateway is the AWS-aware piece. |
| What if Bedrock is denied for the model I picked? | First-time Anthropic-on-Bedrock users get a one-page use-case form on first invoke. Submit once at `bedrock_model_catalog_url`; auto-enable on first invoke does the rest. |
| What's the destroy story? | `terraform destroy` runs `openshift-install destroy cluster` then `ccoctl aws delete` then removes workload IAM roles + VPC. |
