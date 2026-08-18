# ---------------------------------------------------------------------------
# Remote state in S3.
#
# PARTIAL CONFIGURATION on purpose: the bucket name contains the AWS account ID
# (S3 bucket names are globally unique across every account on earth), so it is
# not knowable when this file is written. It is supplied at init time instead:
#
#   terraform init -backend-config="bucket=<name>"
#
# scripts/tf-init.sh reads it out of the bootstrap module's output so you never
# have to type it.
#
# ---------------------------------------------------------------------------
# LOCKING: note what is NOT here -- there is no dynamodb_table.
#
# Until Terraform 1.10, S3 could not do a compare-and-swap, so every tutorial
# provisioned a DynamoDB table purely to hold a lock row. use_lockfile = true
# replaces that: Terraform writes <key>.tflock using S3's conditional write
# (If-None-Match), and a concurrent apply is rejected by S3 itself with 412
# PreconditionFailed. One less piece of infrastructure to create, pay for, and
# forget to delete.
# ---------------------------------------------------------------------------
terraform {
  backend "s3" {
    key          = "platform-lab/aws/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
