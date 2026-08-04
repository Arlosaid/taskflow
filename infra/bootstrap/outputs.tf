output "state_bucket_name" {
  description = "Put this in the backend block of every environment"
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  description = "ARN of the Terraform state bucket"
  value       = aws_s3_bucket.tfstate.arn
}

output "aws_iam_openid_connect_provider_arn" {
  description = "ARN of the OIDC provider"
  value       = aws_iam_openid_connect_provider.github.arn
}
