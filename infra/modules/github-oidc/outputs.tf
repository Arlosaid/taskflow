output "plan_role_arn" {
  description = "ARN of the GitHub plan role"
  value       = aws_iam_role.plan.arn
}

output "deploy_role_arn" {
  description = "ARN of the GitHub deploy role"
  value       = aws_iam_role.deploy.arn
}
