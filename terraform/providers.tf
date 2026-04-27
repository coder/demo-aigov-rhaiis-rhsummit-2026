provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "demo-aigov-rhaiis-rhsummit-2026"
      Environment = "demo"
      ManagedBy   = "terraform"
      Owner       = var.owner_email
    }
  }
}

# Random for unique-suffix resources (RDS final snapshot, etc.)
provider "random" {}

provider "local" {}

provider "null" {}

provider "tls" {}
