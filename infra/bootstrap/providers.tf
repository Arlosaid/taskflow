provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "TaskFlow"
      Environment = "bootstrap"
      ManagedBy   = "Terraform"
      Owner       = "Alonso de la Cruz"
    }
  }
}
