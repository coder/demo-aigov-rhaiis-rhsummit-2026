# Terraform — OpenShift 4.20 IPI on AWS with STS + IRSA

Provisions:
- BYO-VPC (3 AZs) for the OCP cluster
- OIDC provider + platform IAM roles via `ccoctl` (STS mode)
- Workload IAM roles for cert-manager (Route 53) and Coder (Bedrock) with OIDC-federated trust
- OpenShift 4.20+ cluster via **Installer-Provisioned Infrastructure** in `credentialsMode: Manual`
- Operator subscriptions: OpenShift GitOps + cert-manager (RH-supported) + CloudNativePG (community-operators, documented exception)
- IRSA ServiceAccount annotations for workload credential injection
- Argo CD root Application (app-of-apps bootstrap)

After `terraform apply` finishes, Argo CD takes over and syncs the cluster apps from `gitops/apps/`. The CNPG operator generates Coder's DB connection Secret (`coder-app`) on its own.

## Prereqs

- AWS account with admin perms (or scoped enough for OCP IPI + `ccoctl`)
- AWS credentials in shell (`aws sts get-caller-identity` succeeds)
- **`aws` CLI** and **`oc`** binary on `PATH`
- **`openshift-install`** binary (4.20+) on `PATH`
- A **public Route 53 hosted zone** for the cluster's parent domain
- Red Hat **pull secret** at `~/.openshift/pull-secret.json`
- An **SSH public key** for OCP node access
- Terraform >= 1.7 or OpenTofu >= 1.7

Note: `ccoctl` is extracted automatically from the OCP release image during apply.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars

terraform init
terraform plan
terraform apply
```

The `apply` will:
1. Create workload IAM roles for cert-manager + Bedrock (~30 sec)
2. Create the BYO-VPC (~2 min)
3. Render `install-config.yaml` with `credentialsMode: Manual`
4. Run `openshift-install create manifests`
5. Extract `ccoctl` from release image, run `ccoctl aws create-all` (OIDC provider + platform IAM roles)
6. Copy ccoctl manifests into install dir
7. Run `openshift-install create cluster` (~30-45 min, uses STS manifests)
8. Apply operator subscriptions, wait for CRDs
9. Annotate cert-manager and coder ServiceAccounts with IAM role ARNs
10. Apply Argo CD root Application

## Tearing down

```bash
terraform destroy
```

This runs:
1. `openshift-install destroy cluster` (removes OCP-managed AWS resources)
2. `ccoctl aws delete` (removes OIDC S3 bucket + IAM OIDC provider + platform IAM roles)
3. Terraform removes workload IAM roles + VPC

## SNO mode

```hcl
control_plane_count         = 1
control_plane_instance_type = "m6i.4xlarge"
worker_count                = 0
```

## What's NOT here

- **No static IAM users or access keys.** All credentials are STS temporary tokens via IRSA.
- **No RDS / ECR / AWS Secrets Manager.** Postgres runs in-cluster; images on GHCR.
- **No GitHub Actions OIDC role.** GHCR pushes use `GITHUB_TOKEN`.
