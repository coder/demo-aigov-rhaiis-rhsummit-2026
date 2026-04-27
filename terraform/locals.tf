locals {
  # Derived FQDNs
  cluster_fqdn = "${var.cluster_name}.${var.base_domain}"
  apps_domain  = "apps.${local.cluster_fqdn}"

  # Single-Node OpenShift (SNO) when control_plane_count == 1
  is_sno = var.control_plane_count == 1

  # Effective worker count: forced to 0 in SNO mode regardless of var
  effective_worker_count = local.is_sno ? 0 : var.worker_count

  # Tags rolled into resources that don't pick up provider-default tags
  common_tags = {
    Project     = "demo-aigov-rhaiis-rhsummit-2026"
    Environment = "demo"
    ManagedBy   = "terraform"
    Owner       = var.owner_email
  }
}
