# AWS security services — GuardDuty + Inspector.
#
# Managed in Terraform so the demo account's threat-detection + vulnerability-
# scanning posture is reproducible. These were first turned on by hand (`aws
# guardduty create-detector` / `aws inspector2 enable`); the resources below
# adopt that same configuration.
#
# Regional: us-east-1 only (where every demo resource lives). Enabling the
# account-level detector/enabler here automatically covers ALL EC2 instances
# in the region (the 3 OCP masters, the GPU worker, and the GitLab VM) — no
# per-instance wiring needed.
#
# FIRST-TIME ADOPTION (because these already exist from the manual enable):
# import before the first apply so Terraform adopts instead of erroring on
# "already exists":
#
#   terraform import aws_guardduty_detector.main <detector-id>
#   terraform import aws_inspector2_enabler.account <account-id>:EC2
#
# (aws_guardduty_detector_feature maps to UpdateDetector and is idempotent, so
#  it does not need importing.)

# ---------------------------------------------------------------------------
# GuardDuty — foundational threat detection (CloudTrail, DNS, VPC Flow Logs,
# S3, EKS audit, RDS login) comes on automatically with the detector; we also
# turn on agentless EC2/EBS malware protection for the VMs.
# ---------------------------------------------------------------------------

resource "aws_guardduty_detector" "main" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

resource "aws_guardduty_detector_feature" "ebs_malware_protection" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "ENABLED"
}

# ---------------------------------------------------------------------------
# Inspector — EC2 vulnerability (package CVE) scanning for the whole account.
# ---------------------------------------------------------------------------

resource "aws_inspector2_enabler" "account" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["EC2"]
}

# EC2 scan mode = HYBRID (agent-based for SSM-managed instances + agentless
# EBS-snapshot scanning for the rest). The RHCOS cluster nodes cannot run the
# SSM agent, so agentless is what gives them (and any not-yet-SSM-managed VM)
# coverage. The AWS provider has no native resource for the Inspector EC2 scan
# mode, so drive it idempotently via the CLI (same local-exec pattern this repo
# already uses for the OpenShift install). Re-runs only when the mode changes.
resource "null_resource" "inspector_ec2_scan_mode" {
  depends_on = [aws_inspector2_enabler.account]

  triggers = {
    scan_mode = "EC2_HYBRID"
    region    = var.aws_region
    profile   = var.aws_profile == null ? "" : var.aws_profile
  }

  provisioner "local-exec" {
    command = "aws inspector2 update-configuration --region ${self.triggers.region} ${self.triggers.profile != "" ? "--profile ${self.triggers.profile}" : ""} --ec2-configuration '{\"scanMode\":\"${self.triggers.scan_mode}\"}'"
  }
}
