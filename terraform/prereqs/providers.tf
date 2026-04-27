provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "demo-aigov-rhaiis-rhsummit-2026"
      Environment = "demo"
      ManagedBy   = "terraform"
      Component   = "account-prereqs"
      Owner       = var.owner_email
    }
  }
}
