# Terraform remote state for the account-level prereqs TF.
#
# Same S3 bucket + DynamoDB lock table as the cluster TF, different state
# key. See ../backend.tf for the full rationale.
#
# State key:  prereqs/terraform.tfstate  (Route 53 zone management,
#                                          installer IAM user, quota
#                                          validation/requests)
terraform {
  backend "s3" {
    bucket         = "tfstate-coder-demo-aigov-rhsummit-2026-342934376218"
    key            = "prereqs/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tfstate-coder-demo-aigov-rhsummit-2026-tflock"
    encrypt        = true
  }
}
