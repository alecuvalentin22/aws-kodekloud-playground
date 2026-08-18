# ---------------------------------------------------------------------------
# The state bucket, and only the state bucket.
#
# THE CHICKEN-AND-EGG: every other root module keeps its state in S3, but the
# bucket that holds it has to be created by Terraform too -- and it cannot keep
# its own state inside itself. So this module deliberately uses LOCAL state.
# It creates one bucket, it is tiny, and if its local state is ever lost the
# bucket can simply be re-imported.
#
# That is the whole reason this is a separate directory rather than a few
# resources bolted onto terraform/aws.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  # No backend block on purpose -- state is local. See above.
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# S3 bucket names are globally unique across every AWS account on earth, so a
# fixed name like "platform-lab-tfstate" will collide. Account ID makes it
# unique without being random, which means `apply` is reproducible.
resource "aws_s3_bucket" "state" {
  bucket = "${var.prefix}-tfstate-${data.aws_caller_identity.current.account_id}"

  # A throwaway playground gets destroyed with the session. In a real account
  # you want prevent_destroy = true here.
  force_destroy = var.force_destroy

  tags = { Name = "${var.prefix}-tfstate" }
}

# Versioning is not optional for state. A bad apply, a partial write or a
# `terraform state rm` fired at the wrong resource is recoverable ONLY if the
# previous object version still exists.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# State contains everything: RDS passwords, private IPs, key material that
# providers happen to return. It is a secrets file that looks like JSON.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning without expiry means every apply accumulates forever. Keep enough
# history to roll back a mistake, not enough to pay for it.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}
