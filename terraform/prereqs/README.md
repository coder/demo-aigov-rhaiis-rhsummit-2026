# Terraform — account-level prereqs

Run this **once per AWS account** before `terraform/main.tf`. Provisions the things you'd otherwise click around the AWS console for:

| What | Why |
|---|---|
| **Public Route 53 hosted zone** for the cluster's `base_domain` | OCP IPI validates the domain before installing; needs an authoritative public zone |
| **Dedicated IAM user** (`ocp-installer-<cluster_name>`) with `AdministratorAccess` + access keys | Decouples the cluster lifecycle from your personal credentials; demo-grade (long-lived keys) — production should swap to IAM Identity Center / SSO |
| **Service quota validation** for EC2 vCPU, Elastic IPs, VPCs, Internet Gateways, Route 53 hosted zones | Quota shortfall is the #1 reason an OCP IPI install fails 25 minutes in |
| **Optional quota-increase requests** (`request_quota_increases = true`) | Filed via the Service Quotas API. Some auto-approve, some require a support case (hours to days) |

> **Run this AT LEAST a week before the booth date** if your account is new — vCPU quota increases for new accounts can sit in support queues.

## Usage

```bash
cd terraform/prereqs
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: base_domain, owner_email, cluster_name, instance types
terraform init
terraform plan
terraform apply
```

Apply will:

1. Read your current AWS service quotas via the Service Quotas API
2. **Hard-fail at plan** if any required quota is below the computed need (set `fail_on_quota_shortfall = false` to bypass)
3. Optionally file increase requests if `request_quota_increases = true`
4. Create the Route 53 hosted zone (if `manage_hosted_zone = true`)
5. Create the IAM installer user + access keys (if `create_installer_iam = true`)

When done, follow the `next_steps` output:

- **If you created a new zone:** delegate the printed NS records at your registrar. Verify with `dig +short NS <base_domain>`.
- **If you created the installer IAM user:** export the access key + secret (or write to `~/.aws/credentials` as a profile) before running the cluster TF.

## Quotas computed from instance types

The required EC2 vCPU is computed from your cluster shape:

```
required_vcpus = (control_plane_count × cp_vcpus) +
                 (worker_count        × worker_vcpus) +
                 bootstrap_vcpus + 12 (buffer)
```

Bootstrap is one additional CP-shaped node that exists only during install (~30 min) but counts against quota during that window.

For the default 3-CP HA cluster (`m6i.xlarge` CP, `m6i.2xlarge` workers): `(3×4) + (3×8) + 4 + 12 = 52 vCPU`.

For SNO (`m6i.4xlarge` × 1, no workers): `(1×16) + 0 + 16 + 12 = 44 vCPU`.

## SCPs and Organizations

If your AWS account is inside an Organization with Service Control Policies that restrict EC2, IAM, or Route 53 actions, this Terraform won't help you — you'll see permission denials at apply. Talk to your Org admin first.

## Tearing down

```bash
terraform destroy
```

Removes the hosted zone, IAM user + keys. Quota increases are NOT rolled back (Service Quotas doesn't support decrease via API).

## What's NOT here yet

- VPC + subnet pre-provisioning ("BYO-VPC" install). The OCP installer creates its own VPC by default; if you want to install into an existing one, edit `../install-config.yaml.tftpl` and add VPC pre-provisioning here.
- AWS Backup / SCP exemptions / Config rules tweaks for the cluster's resources.
- IAM Identity Center / SSO integration for the installer.
