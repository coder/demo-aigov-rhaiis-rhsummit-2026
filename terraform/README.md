# Terraform — OpenShift 4.21 IPI on AWS with STS + IRSA

Provisions:
- BYO-VPC (3 AZs) for the OCP cluster
- OIDC provider + platform IAM roles via `ccoctl` (STS mode)
- Workload IAM roles for cert-manager (Route 53) and Coder (Bedrock) with OIDC-federated trust
- OpenShift 4.21+ cluster via **Installer-Provisioned Infrastructure** in `credentialsMode: Manual` — compact 3-node converged shape (`compute.replicas: 0`) plus a dedicated GPU compute pool (`gpu_count` × `gpu_instance_type`, default 1× g5.2xlarge in us-east-1a)
- Operator subscriptions: OpenShift GitOps + cert-manager + NFD (RH-supported) + CloudNativePG (community-operators) + NVIDIA GPU operator (certified-operators, NVIDIA-engineered + RH-certified)
- IRSA ServiceAccount annotations for workload credential injection
- Argo CD root Application (app-of-apps bootstrap)

After `terraform apply` finishes, Argo CD takes over and syncs the cluster apps from `gitops/apps/` (Postgres CNPG cluster, Coder Helm chart, RHAIIS, Agent Firewalls). The CNPG operator generates Coder's DB connection Secret (`coder-app` in the `coder` namespace) on its own — there is no out-of-band DB URL to manage.

## Prereqs

- AWS account with admin perms (or scoped enough for OCP IPI + `ccoctl`)
- AWS credentials in shell (`aws sts get-caller-identity` succeeds)
- **`aws` CLI**, **`oc`**, and **`openshift-install`** (4.21+) on `PATH`
- A **public Route 53 hosted zone** for the cluster's parent domain (e.g., `rh.coderdemo.io`)
- Red Hat **pull secret** at `~/.openshift/pull-secret.json` — download from <https://console.redhat.com/openshift/install/pull-secret>
- An **SSH public key** for OCP node access (e.g., `~/.ssh/id_ed25519.pub`)
- Terraform ≥ 1.7 or OpenTofu ≥ 1.7

Note: `ccoctl` is extracted automatically from the OCP release image during apply.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — fill in base_domain, paths to pull secret + ssh key

terraform init
terraform plan
terraform apply
```

The `apply` will:
1. Create workload IAM roles for cert-manager + Bedrock (~30 sec)
2. Create the BYO-VPC (~2 min)
3. Render `install-config.yaml` with `credentialsMode: Manual` (3 CP + GPU compute pool)
4. Run `openshift-install create manifests`
5. Extract `ccoctl` from release image, run `ccoctl aws create-all` (OIDC provider + platform IAM roles)
6. Copy ccoctl manifests into install dir
7. Run `openshift-install create cluster` (~30-45 min, uses STS manifests)
8. Apply operator subscriptions (OpenShift GitOps + cert-manager + CloudNativePG + NFD + NVIDIA GPU operator)
9. Wait for all operator CRDs to land
10. Annotate cert-manager and coder ServiceAccounts with IAM role ARNs
11. Apply Argo CD root Application (kicks off Postgres + GPU stack + Coder + RHAIIS sync). NVIDIA drivers compile + load onto the GPU node (~3–5 min) before RHAIIS pod schedules.

When done, follow the `next_steps` output.

## Tearing down

```bash
terraform destroy
```

This runs:
1. `openshift-install destroy cluster` (removes OCP-managed AWS resources)
2. `ccoctl aws delete` (removes OIDC S3 bucket + IAM OIDC provider + platform IAM roles)
3. Terraform removes workload IAM roles + VPC

If `openshift-install destroy` fails midway, inspect `./.cluster/` and re-run manually before letting Terraform proceed.

## SNO mode

For sizing experiments (no HA, no GPU, lowest cost), switch to **Single-Node OpenShift**:

```hcl
control_plane_count         = 1
control_plane_instance_type = "m6i.8xlarge"   # 32 vCPU / 128 GiB — needed because RHAIIS-on-CPU lands here
worker_count                = 0
gpu_count                   = 0
```

NOTE: SNO loses the multi-AZ HA narrative AND the GPU narrative. CNPG must be dropped to `instances: 1`, and you'll need to swap RHAIIS to `vllm-cpu-rhel9` (the shipped manifest is GPU-only). Use only for non-booth experiments where cost dominates.

## What's NOT here

- **No static IAM users or access keys.** All credentials are STS temporary tokens via IRSA.
- **No RDS / ECR / AWS Secrets Manager.** Postgres runs in-cluster (CNPG operator); workspace base images live on GHCR.
- **No GitHub Actions OIDC role.** GHCR pushes use `GITHUB_TOKEN`.
- **STIG/FIPS posture, OCP `restricted-v2` SCC overrides, air-gap config** — production-only.
