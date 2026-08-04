resource "aws_s3_bucket" "tfstate" {
  #checkov:skip=CKV2_AWS_62:State changes have no event-driven consumer in this bootstrap module.
  #checkov:skip=CKV_AWS_144:Cross-region replication requires a separately managed DR bucket and is out of scope here.
  #checkov:skip=CKV_AWS_18:Access logging requires a separately managed log bucket; CloudTrail is the account-level audit source.
  #checkov:skip=CKV_AWS_145:SSE-S3 is intentional for this low-cost state bucket; a customer-managed KMS key adds unnecessary key management.
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true # a stray `terraform destroy` cannot delete your state
  }
}

# Versioning: every state write keeps the previous version.
# This is your undo button if an apply corrupts state.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encryption at rest. SSE-S3 (AES256) is free; a CMK would add cost and key management
# for no real benefit at this scale — that trade-off goes in an ADR.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# State files contain resource IDs, ARNs, and sometimes sensitive values.
# This bucket must never be public, under any circumstance.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Old state versions accumulate forever otherwise. 90 days is plenty of undo.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
