###############################################################################
# VPC for the OCP IPI install
#
# We pre-provision the VPC instead of letting `openshift-install` create one
# so we control the CIDR layout (no surprise overlap with on-prem ranges)
# and can keep multi-AZ topology consistent across control-plane / worker
# nodes / future helper services in the same network.
#
# OCP IPI install picks this up via `platform.aws.subnets` in install-config
# (BYO-VPC pattern). The installer auto-detects public vs private from the
# subnet route tables.
#
# Three AZs (a/b/c) chosen for control-plane HA. CloudNativePG runs
# in-cluster and uses pod-anti-affinity on topology.kubernetes.io/zone
# (set in manifests/postgres/cluster.yaml) so its replicas spread across
# the same three AZs as the worker nodes.
###############################################################################

locals {
  vpc_azs              = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  vpc_cidr             = "10.0.0.0/16"
  vpc_private_subnets  = ["10.0.0.0/19", "10.0.32.0/19", "10.0.64.0/19"]
  vpc_public_subnets   = ["10.0.128.0/20", "10.0.144.0/20", "10.0.160.0/20"]
  vpc_database_subnets = ["10.0.192.0/21", "10.0.200.0/21", "10.0.208.0/21"]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.cluster_name}-vpc"
  cidr = local.vpc_cidr

  azs              = local.vpc_azs
  private_subnets  = local.vpc_private_subnets
  public_subnets   = local.vpc_public_subnets
  database_subnets = local.vpc_database_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = false # one NAT per AZ — HA, no cross-AZ egress charges on failover
  one_nat_gateway_per_az = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  create_database_subnet_group = true

  # OCP IPI installer requires these tags on subnets it will use. Cluster name
  # tag value is `shared` (vs `owned`) since we own the VPC, not the installer.
  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}
