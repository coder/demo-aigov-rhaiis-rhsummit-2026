# Terraform remote state for the cluster TF.
#
# State + locking live in the demo's sandbox AWS account
# (342934376218). The S3 bucket and DynamoDB lock table are created by
# scripts/bootstrap-tf-backend.sh — run that ONCE per account before any
# `terraform init` here. After that, every teammate with sandbox SSO
# access can plan/apply/destroy from their own laptop; the DynamoDB
# lock prevents concurrent applies stepping on each other.
#
# If you fork this repo to a different AWS account:
#   1. Run scripts/bootstrap-tf-backend.sh against your account; the
#      bucket name auto-incorporates the account ID for global S3
#      uniqueness.
#   2. Update the `bucket` and `dynamodb_table` values below to match
#      what the script printed (or pass `-backend-config=` partial
#      config at `terraform init` time).
#
# State key:  cluster/terraform.tfstate  (the full OCP IPI install +
#                                          IAM users + VPC live here)
terraform {
  backend "s3" {
    bucket         = "tfstate-coder-demo-aigov-rhsummit-2026-342934376218"
    key            = "cluster/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tfstate-coder-demo-aigov-rhsummit-2026-tflock"
    encrypt        = true
  }
}
