variable "github_repository" {
  description = "GitHub repository in the form owner/name"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider"
  type        = string
}


variable "state_bucket_arn" {
  description = "ARN of the Terraform state bucket"
  type        = string
}

variable "state_key_prefix" {
  description = "Prefix for the environment state objects, such as dev/"
  type        = string
}

variable "env" {
  description = "Environment name. IAM role names are account-global, so it must be part of the name."
  type        = string
}
