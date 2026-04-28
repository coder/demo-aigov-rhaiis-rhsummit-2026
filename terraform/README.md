# Terraform — OpenShift 4.21 IPI on AWS + supporting infra

Provisions:
- BYO-VPC (3 AZs) for the OCP cluster
- AWS IAM users for cert-manager (Route 53 DNS-01) and Coder → Bedrock
- OpenShift 4.21+ cluster via **Installer-Provisioned Infrastructure** (`openshift-install create cluster`) — compact 3-node converged shape (`compute.replicas: 0`) plus a dedicated GPU compute pool (`gpu_count` × `gpu_instance_type`, default 1× g5.2xlarge in us-east-1a)
- Operator subscriptions: OpenShift GitOps + cert-manager + NFD (RH-supported) + CloudNativePG (community-operators) + NVIDIA GPU operator (certified-operators, NVIDIA-engineered + RH-certified)
- Cluster Secrets bootstrapped from this Terraform run: `route53-credentials`, `bedrock-credentials`, `redhat-pull-secret`
- Argo CD root Application (app-of-apps bootstrap)

After `terraform apply` finishes, Argo CD takes over and syncs the cluster apps from `gitops/apps/` (Postgres CNPG cluster, Coder Helm chart, RHAIIS, Agent Firewalls). The CNPG operator generates Coder's DB connection Secret (`coder-app` in the `coder` namespace) on its own — there is no out-of-band DB URL to manage.

## Prereqs

- AWS account with admin perms (or scoped enough for OCP IPI: VPC, IAM, EC2, ELB, S3, Route 53)
- AWS credentials in shell (`aws sts get-caller-identity` succeeds)
- A **public Route 53 hosted zone** for the cluster's parent domain (e.g., `rh.coderdemo.io`)
- Red Hat **pull secret** at `~/.openshift/pull-secret.json` — download from <https://console.redhat.com/openshift/install/pull-secret>
- An **SSH public key** for OCP node access (e.g., `~/.ssh/id_ed25519.pub`)
- **`openshift-install`** binary (4.21+) on `PATH` — download from <https://mirror.openshift.com/pub/openshift-v4/clients/ocp/>
- **`oc`** binary on `PATH`
- Terraform ≥ 1.7 or OpenTofu ≥ 1.7

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — fill in base_domain, paths to pull secret + ssh key

terraform init
terraform plan
terraform apply
```

The `apply` will:
1. Create IAM users for cert-manager + Bedrock (~30 sec)
2. Create the BYO-VPC (~2 min)
3. Render `install-config.yaml` into `./.cluster/` (3 CP + GPU compute pool)
4. Run `openshift-install create cluster --dir=./.cluster` (~30–45 min)
5. Apply operator subscriptions (OpenShift GitOps + cert-manager + CloudNativePG + NFD + NVIDIA GPU operator)
6. Wait for all operator CRDs to land (cert-manager, CNPG, NFD, NVIDIA ClusterPolicy)
7. Create cluster Secrets (`route53-credentials`, `bedrock-credentials`, `redhat-pull-secret`)
8. Apply the Argo CD root Application (kicks off Postgres + GPU stack + Coder + RHAIIS + Agent Firewalls sync). NVIDIA drivers compile + load onto the GPU node (~3–5 min) before RHAIIS pod schedules.

When done, follow the `next_steps` output.

## Tearing down

```bash
terraform destroy
```

This runs `openshift-install destroy cluster` first (which removes the OCP-installer-managed EC2 / ELB / S3 / IAM created by the installer), then tears down the IAM users + VPC.

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

## Why no STIG/FIPS

Demo simplicity. The `install-config.yaml.tftpl` doesn't set `fips: true` and the deployed manifests don't override OCP's default `restricted-v2` SCC with anything stricter. For production deployments, see `docs/architecture.md` for the hardening pattern (LMCO POV / UDS Core JREN reference).

## What's NOT here

- **No RDS / ECR / AWS Secrets Manager.** Postgres runs in-cluster (CNPG operator); workspace base images live on GHCR; the few Secrets the cluster needs are created in-line by this Terraform's bootstrap step.
- **No GitHub Actions OIDC role.** GHCR pushes use the workflow's built-in `GITHUB_TOKEN`.
- **STIG/FIPS posture, OCP `restricted-v2` SCC overrides, air-gap config** — production-only.
