data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_s3_bucket" "tfstate" {
  bucket = "taskflow-terraform-state-20260730-001"
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  github_repository = "Arlosaid/taskflow"
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  state_bucket_arn  = data.aws_s3_bucket.tfstate.arn
  state_key_prefix  = "dev/"
}
