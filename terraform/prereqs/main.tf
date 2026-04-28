###############################################################################
# Account-level prerequisites for the OpenShift IPI demo cluster.
#
# Provisions / validates:
#   1. Public Route 53 hosted zone for base_domain (or imports existing)
#   2. Dedicated IAM user for the OCP installer with AdministratorAccess
#      (or skip; use your own creds)
#   3. AWS service quota validation + (optional) increase requests for
#      EC2 vCPU, Elastic IPs, VPCs, IGWs, NAT gateways, hosted zones
#
# Run this ONCE per AWS account before `terraform/main.tf`. Outputs are
# exported for the cluster TF to consume (manually or via remote state).
###############################################################################

###############################################################################
# Data sources
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

###############################################################################
# Locals — derived values
###############################################################################

locals {
  # Approximate vCPU per instance type. Extend as needed.
  vcpu_per_type = {
    "m6i.large"   = 2,
    "m6i.xlarge"  = 4,
    "m6i.2xlarge" = 8,
    "m6i.4xlarge" = 16,
    "m6i.8xlarge" = 32,
    "m5.large"    = 2,
    "m5.xlarge"   = 4,
    "m5.2xlarge"  = 8,
    "m5.4xlarge"  = 16,
    "c6i.xlarge"  = 4,
    "c6i.2xlarge" = 8,
    "r6i.xlarge"  = 4,
    "r6i.2xlarge" = 8,
    # GPU families — quota L-DB2E81BA (G and VT - GPU)
    "g4dn.xlarge"  = 4,
    "g4dn.2xlarge" = 8,
    "g4dn.4xlarge" = 16,
    "g5.xlarge"    = 4,
    "g5.2xlarge"   = 8,
    "g5.4xlarge"   = 16,
    "g5.8xlarge"   = 32,
  }

  cp_vcpus_per_node     = lookup(local.vcpu_per_type, var.control_plane_instance_type, 4)
  worker_vcpus_per_node = lookup(local.vcpu_per_type, var.worker_instance_type, 8)
  gpu_vcpus_per_node    = lookup(local.vcpu_per_type, var.gpu_instance_type, 8)

  # Bootstrap node uses the same shape as a control-plane node, exists only
  # during install (~30 min) but counts against vCPU during that window.
  bootstrap_vcpus = local.cp_vcpus_per_node

  # Buffer for: rolling OS updates, day-2 ops, accidental scale-out
  vcpu_buffer = 12

  # Standard On-Demand vCPU need (CP + workers + bootstrap + buffer).
  # GPU vCPU is a SEPARATE quota — see required_gpu_vcpus.
  required_vcpus = (
    (var.control_plane_count * local.cp_vcpus_per_node) +
    (var.worker_count * local.worker_vcpus_per_node) +
    local.bootstrap_vcpus +
    local.vcpu_buffer
  )

  # GPU vCPU need (separate quota). 0 when gpu_count = 0.
  required_gpu_vcpus = var.gpu_count * local.gpu_vcpus_per_node

  # Other quota minimums for OCP IPI on AWS
  required_eips         = 5 # NAT GWs (1 per AZ) + ELB EIPs
  required_vpcs         = 1 # plus existing
  required_igws         = 1 # plus existing
  required_hosted_zones = 1 # plus existing
}

###############################################################################
# Route 53 — public hosted zone
###############################################################################

resource "aws_route53_zone" "base" {
  count   = var.manage_hosted_zone ? 1 : 0
  name    = var.base_domain
  comment = "Public hosted zone for OCP demo cluster ${var.cluster_name}"
}

data "aws_route53_zone" "existing" {
  count        = var.manage_hosted_zone ? 0 : 1
  name         = var.base_domain
  private_zone = false
}

###############################################################################
# IAM — OCP installer user
###############################################################################

resource "aws_iam_user" "ocp_installer" {
  count = var.create_installer_iam ? 1 : 0
  name  = "ocp-installer-${var.cluster_name}"
  path  = "/demo/"
}

resource "aws_iam_user_policy_attachment" "ocp_installer" {
  count      = var.create_installer_iam ? 1 : 0
  user       = aws_iam_user.ocp_installer[0].name
  policy_arn = var.installer_iam_policy_arn
}

resource "aws_iam_access_key" "ocp_installer" {
  count = var.create_installer_iam ? 1 : 0
  user  = aws_iam_user.ocp_installer[0].name
}

###############################################################################
# Service quotas — read current, validate, optionally request increase
#
# Quota codes from `aws service-quotas list-service-quotas`. If a code below
# is wrong for your account/region, look it up via the AWS console URL:
#   https://<region>.console.aws.amazon.com/servicequotas/home/services
###############################################################################

# EC2 — Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances vCPU
data "aws_servicequotas_service_quota" "ec2_standard_vcpus" {
  service_code = "ec2"
  quota_code   = "L-1216C47A"
}

# EC2 — Running On-Demand G and VT (GPU) instances vCPU. Separate quota
# from standard On-Demand. New AWS accounts often start at 0 here and
# require a case-based approval (slower than auto-approved standard
# vCPU bumps). File this AT LEAST a week before booth.
data "aws_servicequotas_service_quota" "ec2_gpu_vcpus" {
  count        = var.gpu_count > 0 ? 1 : 0
  service_code = "ec2"
  quota_code   = "L-DB2E81BA"
}

# EC2 — EIPs in current region
data "aws_servicequotas_service_quota" "ec2_eips" {
  service_code = "ec2"
  quota_code   = "L-0263D0A3"
}

# VPC — VPCs per Region
data "aws_servicequotas_service_quota" "vpc_per_region" {
  service_code = "vpc"
  quota_code   = "L-F678F1CE"
}

# VPC — Internet gateways per Region
data "aws_servicequotas_service_quota" "vpc_igw_per_region" {
  service_code = "vpc"
  quota_code   = "L-A4707A72"
}

# Route 53 — Hosted zones (account-level, region not relevant)
data "aws_servicequotas_service_quota" "route53_hosted_zones" {
  service_code = "route53"
  quota_code   = "L-ACB674F3"
}

###############################################################################
# Quota validation (hard-fail at plan when fail_on_quota_shortfall=true)
###############################################################################

resource "terraform_data" "validate_quotas" {
  triggers_replace = [
    data.aws_servicequotas_service_quota.ec2_standard_vcpus.value,
    data.aws_servicequotas_service_quota.ec2_eips.value,
    local.required_vcpus,
  ]

  lifecycle {
    precondition {
      condition = !var.fail_on_quota_shortfall || (
        data.aws_servicequotas_service_quota.ec2_standard_vcpus.value >= local.required_vcpus
      )
      error_message = <<-EOT

        EC2 vCPU quota too low.

          Current quota:  ${data.aws_servicequotas_service_quota.ec2_standard_vcpus.value} vCPU
          Required:       ${local.required_vcpus} vCPU
              = (${var.control_plane_count} CP × ${local.cp_vcpus_per_node} vCPU) +
                (${var.worker_count} workers × ${local.worker_vcpus_per_node} vCPU) +
                ${local.bootstrap_vcpus} bootstrap + ${local.vcpu_buffer} buffer

        Fix one of:
          (a) request_quota_increases = true in this Terraform — files an
              increase ticket via Service Quotas API (auto-approves for some,
              support-case for others; can take hours to days)
          (b) request manually in the AWS console:
              https://${var.aws_region}.console.aws.amazon.com/servicequotas/home/services/ec2/quotas
          (c) reduce control_plane_count / worker_count / instance_type in
              both this and the cluster TF
          (d) set fail_on_quota_shortfall = false to bypass this check
              (only if you've already filed a request and are waiting)

      EOT
    }

    precondition {
      condition = !var.fail_on_quota_shortfall || (
        data.aws_servicequotas_service_quota.ec2_eips.value >= local.required_eips
      )
      error_message = <<-EOT

        EC2 Elastic IP quota too low.

          Current quota:  ${data.aws_servicequotas_service_quota.ec2_eips.value}
          Required:       ${local.required_eips}

        OCP IPI provisions one EIP per NAT gateway (one per AZ) plus EIPs for
        load balancers. Increase via Service Quotas:
          https://${var.aws_region}.console.aws.amazon.com/servicequotas/home/services/ec2/quotas

      EOT
    }

    precondition {
      condition = !var.fail_on_quota_shortfall || var.gpu_count == 0 || (
        data.aws_servicequotas_service_quota.ec2_gpu_vcpus[0].value >= local.required_gpu_vcpus
      )
      error_message = <<-EOT

        EC2 GPU vCPU quota too low (separate from standard On-Demand vCPU).

          Current quota:  ${var.gpu_count > 0 ? tostring(data.aws_servicequotas_service_quota.ec2_gpu_vcpus[0].value) : "n/a"} vCPU
          Required:       ${local.required_gpu_vcpus} vCPU
              = ${var.gpu_count} GPU node × ${local.gpu_vcpus_per_node} vCPU (${var.gpu_instance_type})

        New AWS accounts often start at 0 GPU vCPU. The increase request is
        CASE-BASED (not auto-approved). File via:
          https://${var.aws_region}.console.aws.amazon.com/servicequotas/home/services/ec2/quotas
        Search for: "Running On-Demand G and VT instances".

      EOT
    }
  }
}

###############################################################################
# Optional quota increase requests (separate from validation)
###############################################################################

resource "aws_servicequotas_service_quota" "ec2_standard_vcpus" {
  count = var.request_quota_increases && data.aws_servicequotas_service_quota.ec2_standard_vcpus.value < local.required_vcpus ? 1 : 0

  service_code = "ec2"
  quota_code   = "L-1216C47A"
  value        = local.required_vcpus
}

resource "aws_servicequotas_service_quota" "ec2_gpu_vcpus" {
  count = (
    var.request_quota_increases
    && var.gpu_count > 0
    && data.aws_servicequotas_service_quota.ec2_gpu_vcpus[0].value < local.required_gpu_vcpus
  ) ? 1 : 0

  service_code = "ec2"
  quota_code   = "L-DB2E81BA"
  value        = local.required_gpu_vcpus
}

resource "aws_servicequotas_service_quota" "ec2_eips" {
  count = var.request_quota_increases && data.aws_servicequotas_service_quota.ec2_eips.value < local.required_eips ? 1 : 0

  service_code = "ec2"
  quota_code   = "L-0263D0A3"
  value        = local.required_eips
}
