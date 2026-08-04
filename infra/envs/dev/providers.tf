provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "TaskFlow"
      Environment = "dev"
      ManagedBy   = "Terraform"
      Owner       = "Alonso de la Cruz"
    }
  }
}
