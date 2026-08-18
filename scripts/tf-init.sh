#!/usr/bin/env bash
# Initialise a root module against the remote state bucket, creating the bucket
# first if it does not exist yet.
#
#   ./scripts/tf-init.sh          # -> terraform/aws
#   ./scripts/tf-init.sh eks      # -> terraform/eks
#
# Why a script: the bucket name contains the AWS account ID, so it cannot be
# hardcoded in backend.tf. Rather than copy-pasting it between two modules,
# read it straight out of the bootstrap module's output.
set -euo pipefail

STACK="${1:-aws}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$HERE/terraform/bootstrap"
TARGET="$HERE/terraform/$STACK"

[[ -d "$TARGET" ]] || { echo "No such stack: terraform/$STACK" >&2; exit 1; }

command -v terraform >/dev/null || { echo "terraform not on PATH" >&2; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || {
  echo "AWS credentials are not working. Export them first:" >&2
  echo "  export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=us-east-1" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# ACCOUNT GUARD.
#
# This laptop has production AWS profiles configured. `terraform apply` reads
# whatever credentials happen to be in the environment, and an exported
# AWS_PROFILE from an earlier shell is invisible until it is too late.
#
# So: print the account this is about to build in, and require it to be
# allow-listed. Put the lab account ID in LAB_ACCOUNT_IDS (env var or the
# default below) once you know it.
# ---------------------------------------------------------------------------
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
LAB_ACCOUNT_IDS="${LAB_ACCOUNT_IDS:-}"

echo "==> AWS account : $ACCOUNT_ID"
echo "==> Identity    : $CALLER_ARN"
echo "==> Region      : ${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"
echo "==> Profile     : ${AWS_PROFILE:-<none, using env or default>}"

if [[ -n "$LAB_ACCOUNT_IDS" ]]; then
  if [[ ",$LAB_ACCOUNT_IDS," != *",$ACCOUNT_ID,"* ]]; then
    echo >&2
    echo "REFUSING: account $ACCOUNT_ID is not in LAB_ACCOUNT_IDS ($LAB_ACCOUNT_IDS)." >&2
    echo "If this really is the lab account, add it:" >&2
    echo "  export LAB_ACCOUNT_IDS=$ACCOUNT_ID" >&2
    exit 1
  fi
else
  echo
  echo "LAB_ACCOUNT_IDS is not set, so this cannot be checked automatically."
  read -r -p "Build the lab in account $ACCOUNT_ID? Type the account ID to confirm: " CONFIRM
  [[ "$CONFIRM" == "$ACCOUNT_ID" ]] || { echo "Aborted." >&2; exit 1; }
fi

echo "==> Ensuring the state bucket exists (terraform/bootstrap, local state)"
terraform -chdir="$BOOTSTRAP" init -input=false >/dev/null
terraform -chdir="$BOOTSTRAP" apply -input=false -auto-approve

BUCKET="$(terraform -chdir="$BOOTSTRAP" output -raw state_bucket)"
REGION="$(terraform -chdir="$BOOTSTRAP" output -raw region)"
echo "==> State bucket: $BUCKET"

echo "==> terraform init -backend-config=bucket=$BUCKET  (terraform/$STACK)"
terraform -chdir="$TARGET" init -input=false -reconfigure \
  -backend-config="bucket=$BUCKET" \
  -backend-config="region=$REGION"

cat <<MSG

Ready. Next:

  cd terraform/$STACK
  terraform plan
  terraform apply

State now lives in s3://$BUCKET/, versioned and encrypted, with locking done by
S3 conditional writes -- no DynamoDB table anywhere.
MSG
