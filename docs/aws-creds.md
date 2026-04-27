# AWS credentials — what's needed, where, and why

> **IAM role-based.** No static IAM user access keys. Cluster workloads
> use IAM roles assumed via EC2 instance metadata (STS AssumeRole),
> which is compatible with AWS accounts that enforce MFA on IAM users.
> Last updated 2026-04-27.

Three personas hold AWS credentials in this demo:

1. **You** — the human running Terraform and the scripts in `scripts/`.
2. **The cluster** — two scoped IAM roles this repo's Terraform creates, plus the IPI installer's instance profiles for the OCP nodes.
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
- The Terraform AWS provider, `openshift-install`, and the `aws` CLI all use the **same SDK credential chain** (`AWS_PROFILE` env var -> `~/.aws/credentials` -> instance metadata). So if `aws sts get-caller-identity` works in your shell, TF will work.
- We don't ship a dedicated installer IAM user by default. `terraform/prereqs/main.tf` *can* create `ocp-installer-<cluster_name>` with `AdministratorAccess` (`var.create_installer_iam = true`) if you'd rather decouple the cluster lifecycle from your personal creds.

---

## Operation-time — cluster running

The cluster TF creates **two** scoped IAM roles at apply time. The IPI installer creates a third class (instance profiles) automatically. All three serve different consumers:

| IAM role | Created by | Permissions | How pods authenticate | Consumed by |
|---|---|---|---|---|
| `<cluster_name>-cert-manager-route53` | `terraform/irsa.tf` — `aws_iam_role.cert_manager` | `route53:GetChange`, `ChangeResourceRecordSets`, `ListResourceRecordSets` scoped to the `base_domain` zone ARN; `ListHostedZonesByName` on `*` | cert-manager uses ambient EC2 IMDS credentials to `sts:AssumeRole` into this role. The `role` field in the ClusterIssuer tells cert-manager which ARN to assume. | cert-manager DNS-01 ACME challenge solver — issues the `*.coder.apps.<cluster>.<base_domain>` wildcard cert against Let's Encrypt prod |
| `<cluster_name>-coder-bedrock` | `terraform/irsa.tf` — `aws_iam_role.coder_bedrock` | `bedrock:InvokeModel*`, `Converse*`, `ListFoundationModels`, `GetFoundationModel`, `List*InferenceProfile*`, `Get*InferenceProfile*` on `Resource: "*"` (demo only) | Coder pod mounts ConfigMap `bedrock-aws-config` as an AWS shared-config file. The Go AWS SDK reads `role_arn` + `credential_source = Ec2InstanceMetadata` and handles the STS AssumeRole chain. | Coder server pod -> AI Gateway's Bedrock provider picks up credentials via the AWS SDK ambient chain (per `coder/coder#24397`, v2.33-rc.3) |
| **OCP IPI instance profiles** | `openshift-install` itself, not this Terraform | EC2 / EBS / ELB / S3 (ignition bucket) / internal Route 53 zone / IAM lifecycle as needed for `machine-api`, `kube-controller-manager`, `aws-ebs-csi-driver`, ELB controller | EC2 instance metadata on every CP + worker node | OCP system controllers — node lifecycle, EBS volumes, ELB / NLB provisioning, ignition bootstrap |

### How IAM role assumption works (IMDS + AssumeRole)

1. The OCP IPI installer creates EC2 instance profiles with IAM roles for master and worker nodes.
2. Our Terraform creates scoped IAM roles with trust policies that allow the OCP node roles to call `sts:AssumeRole`.
3. The bootstrap step adds an inline `sts:AssumeRole` policy to the node roles (discovered at runtime via `oc get infrastructure cluster`).
4. Pods on OCP nodes access EC2 IMDS to get temporary credentials for the node role.
5. The AWS SDK chains these into an `sts:AssumeRole` call to the target service role, getting scoped, temporary credentials.

No static access keys are involved. All credentials are STS-issued and auto-expire.

### Why IAM roles instead of IAM users

- **MFA compatibility.** AWS accounts with MFA policies deny API calls from IAM user access keys that lack MFA context. Pods cannot provide MFA, so static user keys fail. IAM roles assumed via IMDS bypass this because the trust relationship is between AWS services, not users.
- **No long-lived secrets.** No access keys stored in K8s Secrets or TF state. STS credentials auto-expire (default 1 hour, renewed automatically by the SDK).
- **Auditable.** CloudTrail logs show which role was assumed and from which instance, providing better attribution than shared access keys.

---

## AWS Bedrock model access — one-time, manual, human

Bedrock is gated **per AWS account, per region, per model** by a human approval in the AWS console:

```
https://${AWS_REGION}.console.aws.amazon.com/bedrock/home?region=${AWS_REGION}#/modelaccess
```

The Terraform `bedrock_model_access_url` output is a direct link. Approval is typically instant for Anthropic models. After approval, the Coder pod's assumed role can invoke them.

There is no API equivalent for this approval step. It is the only piece of the demo that requires a console session.

---

## Lifecycle and rotation

- **IAM roles live in TF state** (ARNs, not secrets). `terraform destroy` deletes the two scoped roles. `openshift-install destroy cluster` (run as the destroy provisioner) cleans up the IPI installer's instance profiles and the inline `assume-demo-service-roles` policies on node roles.
- **No credential rotation needed.** STS temporary credentials issued via AssumeRole auto-expire and are renewed by the AWS SDK. There are no static keys to rotate.
- **Sandbox profile rotation** is on you / your AWS Org policy. TF state doesn't depend on which session token your sandbox profile happens to have at apply time.
- **GitHub PAT rotation** — `gh auth refresh` covers it. No AWS coupling.

---

## What's stored where on disk

| Where | What | Sensitivity |
|---|---|---|
| `~/.aws/credentials` | Sandbox + parent profile static keys (yours) | High — your laptop |
| `terraform/.terraform.tfstate` (after apply) | IAM role ARNs (no secrets) | Low — ARNs are not secrets |
| `${install_dir}/auth/kubeconfig` | Cluster kubeadmin kubeconfig | High — full cluster admin |
| `${install_dir}/auth/kubeadmin-password` | Initial kubeadmin password | High |
| `~/.openshift/pull-secret.json` | RH partner pull-secret (yours) | High — pulls from `registry.redhat.io` |

`.gitignore` covers all `*.tfstate` and the cluster install dir is `./.cluster/` which is gitignored. Even so:

- Back the install dir + tfstate up to encrypted storage if you stop trusting the laptop disk.
- Move TF state to **S3 with KMS encryption + DynamoDB locking** when you implement remote state (planned in the cluster-up/down lifecycle work).

---

## Production-hardening checklist (beyond booth scope)

- Switch to **full OIDC-based IRSA** with `credentialsMode: Manual` in `install-config.yaml` + `ccoctl` for per-ServiceAccount role isolation. The current IMDS-based AssumeRole gives node-level (not pod-level) credential scope.
- Scope the Bedrock IAM role from `Resource: "*"` to the specific model + inference-profile ARNs you've actually approved.
- Move K8s config behind a real secrets manager with audit (Vault on OCP, ESO + AWS SM, etc.).
- Remote TF state on S3 + DynamoDB lock (planned).
- Service-control-policy (SCP) review at the AWS Organizations level if the sandbox account is in an Org.
- Deploy the [EKS Pod Identity Webhook](https://github.com/aws/amazon-eks-pod-identity-webhook) on OpenShift for per-pod credential isolation without full STS mode.

---

## Quick reference

| Question | Answer |
|---|---|
| Who needs AWS creds to run `terraform apply`? | You — sandbox profile, account-admin level. |
| Who needs AWS creds in GitHub Actions? | Nobody. Removed with the GHCR migration. |
| What can the cert-manager role do? | Edit Route 53 records in the cluster's `base_domain` zone. Nothing else. |
| What can the coder-bedrock role do? | Invoke Bedrock models (any). Nothing else. |
| How does AI Gateway find Bedrock creds? | AWS SDK ambient chain — reads ConfigMap-mounted AWS config with `role_arn` + `credential_source = Ec2InstanceMetadata`, then AssumeRole via IMDS. |
| Where does the workspace get AWS creds? | It doesn't. Workspaces talk to AI Gateway only; AI Gateway is the AWS-aware piece. |
| What if Bedrock is denied for the model I picked? | One-time human click in the Bedrock console at `bedrock_model_access_url`. |
| What's the destroy story? | `terraform destroy` removes both scoped roles; `openshift-install destroy cluster` (wrapped) cleans up the IPI-managed instance profiles. |
