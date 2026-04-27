# Terraform — OpenShift 4.20 IPI on AWS + supporting infra

Provisions:
- AWS RDS Aurora Postgres (Coder DB)
- AWS ECR repositories (workspace base images)
- AWS IAM role + OIDC provider for GitHub Actions (push to ECR)
- OpenShift 4.20+ cluster via **Installer-Provisioned Infrastructure** (`openshift-install create cluster`)
- OpenShift GitOps operator + Argo CD root Application (app-of-apps bootstrap)

After `terraform apply` finishes, Argo CD takes over and syncs the cluster apps from `gitops/apps/` (Coder Helm chart, RHAIIS, Agent Firewalls).

## Prereqs

- AWS account with admin perms (or scoped enough for OCP IPI: VPC, IAM, EC2, ELB, S3, Route 53)
- AWS credentials in shell (`aws sts get-caller-identity` succeeds)
- A **public Route 53 hosted zone** for the cluster's parent domain (e.g., `aws.example.com`)
- Red Hat **pull secret** at `~/.openshift/pull-secret.json` — download from <https://console.redhat.com/openshift/install/pull-secret>
- An **SSH public key** for OCP node access (e.g., `~/.ssh/id_ed25519.pub`)
- **`openshift-install`** binary (4.20+) on `PATH` — download from <https://mirror.openshift.com/pub/openshift-v4/clients/ocp/>
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
1. Create RDS / ECR / IAM (~3 min)
2. Render `install-config.yaml` into `./.cluster/`
3. Run `openshift-install create cluster --dir=./.cluster` (~30–45 min)
4. Apply OpenShift GitOps operator subscription + wait for Argo CD ready
5. Apply Argo CD root Application (kicks off Coder + RHAIIS + Agent Firewalls sync)

When done, follow the `next_steps` output.

## Tearing down

```bash
terraform destroy
```

This runs `openshift-install destroy cluster` first (which removes the OCP-installer-managed VPC / EC2 / IAM / ELB / S3), then RDS / ECR / IAM.

If `openshift-install destroy` fails midway, inspect `./.cluster/` and re-run manually before letting Terraform proceed.

## SNO mode

For the cheapest possible demo (~$0.40–0.80/hr), switch to **Single-Node OpenShift**:

```hcl
control_plane_count         = 1
control_plane_instance_type = "m6i.4xlarge"   # 16 vCPU / 64 GiB
worker_count                = 0
```

SNO is fine for the booth — Coder + RHAIIS + GitOps + monitoring all fit in 64 GiB. You lose HA stories but gain provisioning speed and cost.

## Why no STIG/FIPS

Demo simplicity. The `install-config.yaml.tftpl` doesn't set `fips: true` and the deployed manifests don't override OCP's default `restricted-v2` SCC with anything stricter. For production deployments, see `docs/architecture.md` for the hardening pattern (LMCO POV / UDS Core JREN reference).

## What's NOT here yet

- Custom VPC ("BYO-VPC") — the installer creates its own. Edit `install-config.yaml.tftpl` for BYO.
- Multi-AZ RDS — single-AZ Aurora Serverless v2 for demo cost.
- `restricted-v2` SCC overrides for vLLM — not needed at demo grade.
- Air-gap path — production-only.
