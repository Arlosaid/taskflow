variable "github_subject_prefix" {
  description = "Immutable subject prefix taken verbatim from a decoded OIDC token, e.g. repo:owner@123/repo@456. Do NOT assemble this from the repo name: this repo uses immutable subject claims and the plain owner/repo form never matches."
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
