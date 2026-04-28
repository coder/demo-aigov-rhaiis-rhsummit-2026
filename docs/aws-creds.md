# AWS credentials — what's needed, where, and why

> **Demo-grade.** Static IAM access keys throughout. IRSA (IAM Roles for Service Accounts) is the production pattern; out of scope for the booth.
> Last updated 2026-04-27 (commit `be5f0c4`-era).

Three personas hold AWS credentials in this demo:

1. **You** — the human running Terraform and the scripts in `scripts/`.
2. **The cluster** — two scoped IAM users this repo's Terraform creates, plus the IPI installer's instance profiles for the OCP nodes.
3. **AWS Bedrock** — a one-time per-region, per-model human approval in the AWS console, gated by your account.

GitHub Actions has **no AWS creds** after the GHCR migration. CI pushes use `GITHUB_TOKEN`.

---

## Build-time — running Terraform / scripts from your laptop

| Cred | Source | Consumed by | Scope |
|---|---|---|---|
| **Sandbox profile** in `~/.aws/credentials` (or `AWS_PROFILE_SANDBOX` in `.env`) | You — pre-existing in your shell | `terraform apply` (AWS provider + the `null_resource` that calls `openshift-install`); every `aws` CLI call in `scripts/*` | Account-admin in the sandbox AWS account — effectively required for OCP IPI |
| **Parent profile** (optional) | You — separate `~/.aws/credentials` profile in the parent account | `scripts/bootstrap-r53-delegation.sh --parent-profile` only | `route53:ChangeResourceRecordSets` on the parent (`coderdemo.io`) hosted zone. Skip and hand off the JSON change-batch if you don't have it. |
| **GitHub PAT** (`gh auth login`) | You | `gh repo create`, `gh secret set`, repo workflows | Repo-scoped for `coder/*`. Not AWS. |

Notes:
- The Terraform AWS provider, `openshift-install`, and the `aws` CLI all use the **same SDK credential chain** (`AWS_PROFILE` env var → `~/.aws/credentials` → instance metadata). So if `aws sts get-caller-identity` works in your shell, TF will work.
- We don't ship a dedicated installer IAM user by default. `terraform/prereqs/main.tf` *can* create `ocp-installer-<cluster_name>` with `AdministratorAccess` (`var.create_installer_iam = true`) if you'd rather decouple the cluster lifecycle from your personal creds.

---

## Operation-time — cluster running

The cluster TF creates **two** scoped IAM users at apply time. The IPI installer creates a third class (instance profiles) automatically. All three serve different consumers:

| IAM user / role | Created by | Permissions | Where the access key lands in the cluster | Consumed by |
|---|---|---|---|---|
| `<cluster_name>-cert-manager` | `terraform/main.tf` — `aws_iam_user.cert_manager` + `aws_iam_user_policy.cert_manager_route53` | `route53:GetChange`, `ChangeResourceRecordSets`, `ListResourceRecordSets` scoped to the `base_domain` zone ARN; `ListHostedZonesByName` on `*` | K8s Secret `route53-credentials` in the `cert-manager` namespace, written by the TF bootstrap step (`oc create secret generic ... --dry-run=client -o yaml \| oc apply -f -`) | cert-manager DNS-01 ACME challenge solver — issues the `*.coder.apps.<cluster>.<base_domain>` wildcard cert against Let's Encrypt prod |
| `<cluster_name>-coder-bedrock` | `terraform/main.tf` — `aws_iam_user.coder_bedrock` + `aws_iam_user_policy.coder_bedrock` | `bedrock:InvokeModel*`, `Converse*`, `ListFoundationModels`, `GetFoundationModel`, `List*InferenceProfile*`, `Get*InferenceProfile*` on `Resource: "*"` (demo only) | K8s Secret `bedrock-credentials` in the `coder` namespace | Coder server pod env vars (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`) → AI Gateway's Bedrock provider picks them up via the AWS SDK ambient chain (per `coder/coder#24397`, v2.33-rc.3) |
| **OCP IPI instance profiles** | `openshift-install` itself, not this Terraform | EC2 / EBS / ELB / S3 (ignition bucket) / internal Route 53 zone / IAM lifecycle as needed for `machine-api`, `kube-controller-manager`, `aws-ebs-csi-driver`, ELB controller | EC2 instance metadata on every CP + worker node | OCP system controllers — node lifecycle, EBS volumes, ELB / NLB provisioning, ignition bootstrap |

The third one we don't manage. If you ever switch to `credentialsMode: Manual` (STS) and IRSA, you'd own those role ARNs explicitly; for the demo's IPI install they're transparent.

### Why static keys + K8s Secret instead of IRSA

- IRSA requires installing OCP in `credentialsMode: Manual` mode and running `ccoctl` to seed component credentials BEFORE the install completes — adds ~20 min and several manual steps to the apply path.
- The booth target is "minutes from `apply` to a working demo," and the surface area covered by these two scoped IAM users is small (2 users, narrow permissions).
- The README's `## Sizing, cost, and startup time` section calls out static keys as a documented exception; production deployments should reapply LMCO POV–style hardening (IRSA + Vault).

---

## AWS Bedrock model access — first-invoke auto-enable + Anthropic use-case form

AWS retired the per-model "Manage model access" console page in late 2025. Serverless foundation models on Bedrock are now **automatically enabled in your account when first invoked** — no manual activation step.

Two caveats remain:

1. **First-time Anthropic users** (no prior Anthropic-on-Bedrock invocation in this account) are prompted for a one-page use-case form when they open Claude in the Model catalog or first invoke it. Approval is typically minutes; the form is `https://${AWS_REGION}.console.aws.amazon.com/bedrock/home?region=${AWS_REGION}#/foundation-models` → click into the model.
2. **AWS Marketplace models** (NOT Anthropic-direct, but third-party catalog entries) require an admin with Marketplace permissions to invoke the model once before account-wide access kicks in.

Practically, our demo only needs Anthropic Claude (Sonnet/Opus tier) for the cloud provider behind AI Gateway. Smoke-test the activation with `aws bedrock-runtime invoke-model --model-id anthropic.claude-sonnet-4-...` once before the booth — if it returns content, you're set; if it errors with `AccessDeniedException` and a use-case-form pointer, fill the form and retry.

After the first successful invocation, the `coder-bedrock` IAM user's keys (created by the cluster TF) work without any further console interaction.

---

## Lifecycle and rotation

- **All three IAM users live in TF state.** `terraform destroy` deletes the two scoped users we manage. `openshift-install destroy cluster` (run as the destroy provisioner) cleans up the IPI installer's instance profiles. The wiring at `terraform/main.tf:177-205` runs the destroy provisioner before the AWS resources tear down.
- **Rotation in place** for either scoped user:
  ```bash
  cd terraform/
  terraform apply -replace=aws_iam_access_key.cert_manager
  # or
  terraform apply -replace=aws_iam_access_key.coder_bedrock
  ```
  TF will mint a new access key, the bootstrap step re-runs `oc apply -f` (idempotent server-side apply) to update the K8s Secret, and the next pod restart picks up the new value. For a clean rotation:
  ```bash
  oc rollout restart -n cert-manager deployment/cert-manager
  oc rollout restart -n coder       deployment/coder
  ```
- **Sandbox profile rotation** is on you / your AWS Org policy. TF state doesn't depend on which session token your sandbox profile happens to have at apply time.
- **GitHub PAT rotation** — `gh auth refresh` covers it. No AWS coupling.

---

## What's stored where on disk

| Where | What | Sensitivity |
|---|---|---|
| `~/.aws/credentials` | Sandbox + parent profile static keys (yours) | High — your laptop |
| `terraform/.terraform.tfstate` (after apply) | Both scoped IAM users' access key IDs **and secrets** | High — these are operational creds for the live cluster |
| `${install_dir}/auth/kubeconfig` | Cluster kubeadmin kubeconfig | High — full cluster admin |
| `${install_dir}/auth/kubeadmin-password` | Initial kubeadmin password | High |
| `~/.openshift/pull-secret.json` | RH partner pull-secret (yours) | High — pulls from `registry.redhat.io` |

`.gitignore` covers all `*.tfstate` and the cluster install dir is `./.cluster/` which is gitignored. Even so:

- Back the install dir + tfstate up to encrypted storage if you stop trusting the laptop disk.
- Move TF state to **S3 with KMS encryption + DynamoDB locking** when you implement remote state (planned in the cluster-up/down lifecycle work). That gets the access keys off your disk and into IAM-controlled storage.

---

## Production-hardening checklist (intentionally NOT done for booth)

- Replace `cert-manager` and `coder-bedrock` IAM users with **IRSA** + `credentialsMode: Manual` in `install-config.yaml`.
- Scope the Bedrock IAM user from `Resource: "*"` to the specific model + inference-profile ARNs you've actually approved.
- Move K8s Secrets behind a real secrets manager with audit and rotation (Vault on OCP, ESO + AWS SM, etc.). The current refactor explicitly dropped ESO/SM for booth simplicity — see `gitops/operator/cnpg-subscription.yaml` for the broader operator-policy reasoning.
- Remote TF state on S3 + DynamoDB lock (planned).
- Service-control-policy (SCP) review at the AWS Organizations level if the sandbox account is in an Org.

---

## Quick reference

| Question | Answer |
|---|---|
| Who needs AWS creds to run `terraform apply`? | You — sandbox profile, account-admin level. |
| Who needs AWS creds in GitHub Actions? | Nobody. Removed with the GHCR migration. |
| What can the `cert-manager` user do? | Edit Route 53 records in the cluster's `base_domain` zone. Nothing else. |
| What can the `coder-bedrock` user do? | Invoke Bedrock models (any). Nothing else. |
| How does AI Gateway find Bedrock creds? | AWS SDK ambient chain — env vars on the Coder pod from the `bedrock-credentials` Secret. |
| Where does the workspace get AWS creds? | It doesn't. Workspaces talk to AI Gateway only; AI Gateway is the AWS-aware piece. |
| What if Bedrock is denied for the model I picked? | First-time Anthropic-on-Bedrock users get a one-page use-case form on first invoke. Submit once at `bedrock_model_catalog_url`; auto-enable on first invoke does the rest. |
| What's the destroy story? | `terraform destroy` removes both scoped users; `openshift-install destroy cluster` (wrapped) cleans up the IPI-managed instance profiles. |
