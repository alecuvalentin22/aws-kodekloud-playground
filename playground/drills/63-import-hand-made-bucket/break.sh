#!/usr/bin/env bash
# During an incident a teammate created an S3 bucket BY HAND (aws CLI), turned
# versioning on, tagged it and put an export in it. Afterwards they wrote the
# Terraform for it "so we can manage it" -- but never imported it, and got two
# details wrong (tags, versioning). Nothing is in the state, so `terraform plan`
# wants to CREATE a bucket that already exists.
#
# Real AWS, nothing faked. API calls (all mine, name prefix platform-lab-drill63-):
#   s3:CreateBucket, PutBucketVersioning, PutBucketTagging, PutObject, GetObject,
#   ListAllMyBuckets, GetBucketTagging; HeadBucket + the S3 backend's Get/PutObject
#   on the lab state bucket under platform-lab/playground/import-drill/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
source "$HERE/tfimport.sh"
for t in terraform jq aws openssl shasum; do command -v "$t" >/dev/null || die "$t not on PATH"; done

SB=$(tf_bucket) || die "cannot find the lab's state bucket (andrei-lab-tfstate-<account>). Run: make state"
mkdir -p "$STATE/logs"

# Leftovers of an earlier run of THIS drill (only what its record names).
[[ -f $REC ]] && bash "$HERE/reset.sh" >/dev/null 2>&1
rm -rf "$TFDIR"; mkdir -p "$TFDIR"

ACCT=$(aws_account)
NAME="${BUCKET_PREFIX}${ACCT}-$(openssl rand -hex 3)"

# Record FIRST, so reset.sh can clean up even if this script dies half way.
umask 077
cat > "$REC" <<EOF2
BUCKET=$NAME
STATE_BUCKET=$SB
TF_PREFIX=$TF_PREFIX
TFDIR=$TFDIR
EOF2

# --- the hand-made bucket -----------------------------------------------------
aws s3api create-bucket --bucket "$NAME" >/dev/null
aws s3api put-bucket-versioning --bucket "$NAME" --versioning-configuration Status=Enabled
aws s3api put-bucket-tagging --bucket "$NAME" --tagging \
  'TagSet=[{Key=platform-lab-drill,Value=63},{Key=team,Value=payments},{Key=env,Value=staging},{Key=retention,Value=90d}]'
OBJ_KEY="exports/ledger-2026-10.csv"
tmp=$(mktemp)
{ echo "date,account,amount_cents"
  echo "2026-10-01,acme-001,125000"; echo "2026-10-02,acme-007,990"
  echo "2026-10-03,globex-114,4200000"; echo "export-token,$(openssl rand -hex 8),0"; } > "$tmp"
aws s3api put-object --bucket "$NAME" --key "$OBJ_KEY" --body "$tmp" >/dev/null
rm -f "$tmp"

CREATED=$(bucket_created "$NAME")
[[ -n $CREATED ]] || die "the new bucket is not in list-buckets"
OBJ_SHA=$(sha_of_key "$NAME" "$OBJ_KEY")
OBJ_VERSION=$(aws s3api head-object --bucket "$NAME" --key "$OBJ_KEY" --query VersionId --output text)
TAGS=$(bucket_tags "$NAME")
[[ -n $OBJ_SHA && -n $OBJ_VERSION && $OBJ_VERSION != None && -n $TAGS ]] || die "could not read back the bucket's baseline"
cat >> "$REC" <<EOF2
OBJ_KEY=$OBJ_KEY
OBJ_SHA=$OBJ_SHA
OBJ_VERSION=$OBJ_VERSION
CREATED=$CREATED
TAGS=$TAGS
EOF2

# --- the teammate's Terraform root -------------------------------------------------
cat > "$TFDIR/backend.hcl" <<HCL
bucket = "$SB"
region = "$TF_REGION"
HCL
cat > "$TFDIR/aws-env.sh" <<ENV
# Lab credentials into THIS shell (never into ~/.aws):   . ./aws-env.sh
set -a; . "$AWS_CREDS_FILE"; set +a
unset AWS_PROFILE
export AWS_DEFAULT_REGION=$TF_REGION AWS_REGION=$TF_REGION
ENV
cat > "$TFDIR/README.md" <<'MD'
Ledger exports bucket (payments team). State: the lab's state bucket
(backend.hcl), locking by S3 lockfile. Credentials: `. ./aws-env.sh`, then
`terraform init -backend-config=backend.hcl`.
MD
cat > "$TFDIR/main.tf" <<HCL
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    key          = "${TF_KEY}"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
}

# Sam, during the incident: "I made this bucket by hand to get the ledger export
# out. Wrote the Terraform below so we can manage it from now on."
resource "aws_s3_bucket" "ledger_exports" {
  bucket = "$NAME"

  tags = {
    team = "payments"
  }
}

resource "aws_s3_bucket_versioning" "ledger_exports" {
  bucket = aws_s3_bucket.ledger_exports.id

  versioning_configuration {
    status = "Suspended"
  }
}
HCL

export TF_IN_AUTOMATION=1 TF_INPUT=0
cd "$TFDIR"
terraform init -input=false -no-color -backend-config=backend.hcl >"$STATE/logs/drill63-init.log" 2>&1 \
  || die "terraform init failed: $STATE/logs/drill63-init.log"
rc=0
terraform plan -input=false -no-color -detailed-exitcode >"$STATE/logs/drill63-plan.log" 2>&1 || rc=$?
(( rc == 2 )) || die "expected a plan that wants to create the bucket (exit 2), got $rc: $STATE/logs/drill63-plan.log"
grep -q 'aws_s3_bucket.ledger_exports will be created' "$STATE/logs/drill63-plan.log" \
  || die "the plan does not want to create the bucket: $STATE/logs/drill63-plan.log"
