data "aws_iam_policy_document" "plan_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:pull_request"]
    }
  }
}

data "aws_iam_policy_document" "deploy_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:ref:refs/heads/main",
        "repo:${var.github_repository}:environment:dev",
        "repo:${var.github_repository}:environment:prod",
      ]
    }
  }
}

# Plan: lee el state, y escribe únicamente el lock.
data "aws_iam_policy_document" "plan_state_access" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.state_bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.state_key_prefix}*"]
    }
  }

  statement {
    sid       = "ReadState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.state_bucket_arn}/${var.state_key_prefix}terraform.tfstate"]
  }

  # The lock object is the one thing a read-only plan legitimately writes.
  statement {
    sid       = "AcquireStateLock"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.state_bucket_arn}/${var.state_key_prefix}terraform.tfstate.tflock"]
  }
}

# Deploy: apply writes the state itself, not just the lock.
data "aws_iam_policy_document" "deploy_state_access" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.state_bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.state_key_prefix}*"]
    }
  }

  statement {
    sid    = "ReadWriteState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${var.state_bucket_arn}/${var.state_key_prefix}terraform.tfstate",
      "${var.state_bucket_arn}/${var.state_key_prefix}terraform.tfstate.tflock",
    ]
  }
}

resource "aws_iam_role" "plan" {
  name                 = "taskflow-${var.env}-github-plan"
  description          = "Read-only role for terraform plan on pull request"
  assume_role_policy   = data.aws_iam_policy_document.plan_assume_role.json
  max_session_duration = 3600
}

resource "aws_iam_role" "deploy" {
  name                 = "taskflow-${var.env}-github-deploy"
  description          = "Apply role for deploys from main. Permissions grow with the infra."
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume_role.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_state_access" {
  name   = "taskflow-state-access"
  role   = aws_iam_role.plan.name
  policy = data.aws_iam_policy_document.plan_state_access.json # ← plan
}

resource "aws_iam_role_policy" "deploy_state_access" {
  name   = "taskflow-state-access"
  role   = aws_iam_role.deploy.name
  policy = data.aws_iam_policy_document.deploy_state_access.json # ← deploy
}
