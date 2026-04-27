###############################################################################
# Identity / account
###############################################################################

output "aws_account_id" {
  description = "AWS account ID this prereqs root provisioned into."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region these prereqs ran against."
  value       = data.aws_region.current.name
}

###############################################################################
# Route 53
###############################################################################

output "hosted_zone_id" {
  description = "Route 53 public hosted zone ID for base_domain. Pass to cluster TF if it consumes it (currently looked up by name)."
  value       = var.manage_hosted_zone ? aws_route53_zone.base[0].zone_id : data.aws_route53_zone.existing[0].zone_id
}

output "hosted_zone_name_servers" {
  description = <<-EOT
    NS records for the hosted zone. If you created a NEW zone (manage_hosted_zone = true),
    you MUST delegate these at your registrar (or in the parent DNS zone) BEFORE
    running the cluster TF, or the OCP installer's domain validation will fail.
  EOT
  value       = var.manage_hosted_zone ? aws_route53_zone.base[0].name_servers : data.aws_route53_zone.existing[0].name_servers
}

###############################################################################
# IAM — installer credentials
###############################################################################

output "installer_iam_user_name" {
  description = "Name of the IAM user created for the OCP installer (null if create_installer_iam = false)."
  value       = var.create_installer_iam ? aws_iam_user.ocp_installer[0].name : null
}

output "installer_access_key_id" {
  description = "AWS_ACCESS_KEY_ID for the installer user. Set as env var or AWS profile before running cluster TF."
  value       = var.create_installer_iam ? aws_iam_access_key.ocp_installer[0].id : null
  sensitive   = true
}

output "installer_secret_access_key" {
  description = "AWS_SECRET_ACCESS_KEY for the installer user. Treat as a secret."
  value       = var.create_installer_iam ? aws_iam_access_key.ocp_installer[0].secret : null
  sensitive   = true
}

###############################################################################
# Service quotas — observability
###############################################################################

output "current_quotas" {
  description = "Snapshot of the AWS service quotas this prereqs root checked against the requirements derived from your cluster sizing."
  value = {
    ec2_standard_vcpus = {
      current  = data.aws_servicequotas_service_quota.ec2_standard_vcpus.value
      required = local.required_vcpus
      ok       = data.aws_servicequotas_service_quota.ec2_standard_vcpus.value >= local.required_vcpus
    }
    ec2_eips = {
      current  = data.aws_servicequotas_service_quota.ec2_eips.value
      required = local.required_eips
      ok       = data.aws_servicequotas_service_quota.ec2_eips.value >= local.required_eips
    }
    vpcs_per_region = {
      current = data.aws_servicequotas_service_quota.vpc_per_region.value
    }
    igws_per_region = {
      current = data.aws_servicequotas_service_quota.vpc_igw_per_region.value
    }
    hosted_zones = {
      current = data.aws_servicequotas_service_quota.route53_hosted_zones.value
    }
  }
}

###############################################################################
# Next steps
###############################################################################

output "next_steps" {
  description = "What to do after `terraform apply` finishes."
  value       = <<-EOT

    ==============================================================
    Account-level prereqs done. Next steps:
    ==============================================================

    %{if var.manage_hosted_zone~}
    1. DELEGATE THE HOSTED ZONE NS RECORDS at your registrar (or in the
       parent zone) BEFORE running the cluster TF. The NS records are:

           ${join("\n           ", aws_route53_zone.base[0].name_servers)}

       Verify delegation propagated (may take a few minutes):
           dig +short NS ${var.base_domain}

    %{endif~}
    %{if var.create_installer_iam~}
    2. Export the installer credentials (or set up an AWS profile) BEFORE
       running the cluster TF. Pull them out of state:

           export AWS_ACCESS_KEY_ID=$(terraform output -raw installer_access_key_id)
           export AWS_SECRET_ACCESS_KEY=$(terraform output -raw installer_secret_access_key)

       Or write a profile to ~/.aws/credentials:

           aws configure set aws_access_key_id     "$(terraform output -raw installer_access_key_id)"     --profile ocp-installer
           aws configure set aws_secret_access_key "$(terraform output -raw installer_secret_access_key)" --profile ocp-installer
           # then in cluster TF: aws_profile = "ocp-installer"

    %{endif~}
    3. Confirm quotas are healthy:

           terraform output -json current_quotas

    4. Run the cluster TF:

           cd ..
           terraform init
           terraform apply

  EOT
}
