output "github_plan_role_arn" {
  value = module.github_oidc.plan_role_arn
}

output "github_deploy_role_arn" {
  value = module.github_oidc.deploy_role_arn
}
