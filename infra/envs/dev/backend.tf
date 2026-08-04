terraform {
  backend "s3" {
    bucket       = "taskflow-terraform-state-20260730-001"
    key          = "dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
