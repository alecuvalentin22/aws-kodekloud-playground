#!/usr/bin/env bash
# Fixed means: the SAME bucket (creation date, object, versioning, tags) is now in
# Terraform's state -- bucket and versioning resource -- and `terraform plan` is clean.
# AWS API calls: s3:ListAllMyBuckets, HeadObject/GetObject, GetBucketVersioning,
# GetBucketTagging, plus what `terraform plan` / `state pull` do (provider reads of the
# bucket; Get/Put/DeleteObject of state + lockfile in the lab state bucket).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
source "$HERE/tfimport.sh"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
# shellcheck disable=SC1090
source "$REC"
[[ -f $TFDIR/main.tf ]] || { c_bad "$TFDIR/main.tf is gone"; exit 1; }
export TF_IN_AUTOMATION=1 TF_INPUT=0

# 1. The bucket is still THE bucket. Deleting it and letting Terraform re-create it
#    makes every Terraform symptom go away and loses the export.
now_created=$(bucket_created "$BUCKET")
if [[ -z $now_created ]]; then
  c_bad "the bucket $BUCKET is gone from the account"
  echo "PENALTY 100 The bucket was deleted. Its export is gone for good: adopting a bucket means import, never delete-and-recreate."
  exit 1
fi
if [[ $now_created != "$CREATED" ]]; then
  c_bad "the bucket was deleted and re-created (creation date $CREATED -> $now_created)"
  echo "PENALTY 100 Delete-and-recreate gives a new bucket with the same name and none of the data."
  exit 1
fi
c_ok "same bucket as before (created $CREATED)"
if [[ $(sha_of_key "$BUCKET" "$OBJ_KEY") != "$OBJ_SHA" ]]; then
  c_bad "s3://$BUCKET/$OBJ_KEY is missing or changed (sha256 differs from the original export)"; exit 1
fi
ver=$(aws s3api head-object --bucket "$BUCKET" --key "$OBJ_KEY" --query VersionId --output text 2>/dev/null)
if [[ $ver != "$OBJ_VERSION" ]]; then
  c_bad "the export object was replaced (version id changed)"; exit 1
fi
c_ok "the export is untouched (sha256 and version id unchanged)"

# 2. Reality was not bent to fit the teammate's code.
vstat=$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text 2>/dev/null)
if [[ $vstat != Enabled ]]; then
  c_bad "versioning on the bucket is '$vstat', it was Enabled (an apply of the unreviewed plan?). Re-enable it -- in the code, not by hand"; exit 1
fi
c_ok "versioning still Enabled"
if [[ $(bucket_tags "$BUCKET") != "$TAGS" ]]; then
  c_bad "the bucket's tags changed. Were: $TAGS. Now: $(bucket_tags "$BUCKET"). The tags are facts about the bucket; the code has to say them"; exit 1
fi
c_ok "tags unchanged"

# 3. Still the S3 backend of the lab's state bucket, same key.
btype=$(jq -r '.backend.type // empty' "$TFDIR/.terraform/terraform.tfstate" 2>/dev/null)
bbucket=$(jq -r '.backend.config.bucket // empty' "$TFDIR/.terraform/terraform.tfstate" 2>/dev/null)
bkey=$(jq -r '.backend.config.key // empty' "$TFDIR/.terraform/terraform.tfstate" 2>/dev/null)
if [[ $btype != s3 || $bbucket != "$STATE_BUCKET" || $bkey != "$TF_KEY" ]]; then
  c_bad "the backend is no longer s3://$STATE_BUCKET/$TF_KEY (it is '${btype:-none}'). Importing into a throwaway local state fixes nothing"; exit 1
fi

# 4. Both resources are in state, and they are THIS bucket.
st=$(terraform -chdir="$TFDIR" state pull 2>/dev/null)
n_b=$(jq -r --arg b "$BUCKET" '[.resources[]? | select(.mode=="managed" and .type=="aws_s3_bucket") | .instances[]? | select(.attributes.id==$b)] | length' <<<"$st" 2>/dev/null)
n_v=$(jq -r --arg b "$BUCKET" '[.resources[]? | select(.mode=="managed" and .type=="aws_s3_bucket_versioning") | .instances[]? | select(.attributes.bucket==$b)] | length' <<<"$st" 2>/dev/null)
if [[ ${n_b:-0} -lt 1 ]]; then c_bad "the bucket (aws_s3_bucket) is not in the Terraform state: terraform state list"; exit 1; fi
c_ok "aws_s3_bucket is in state"
if [[ ${n_v:-0} -lt 1 ]]; then c_bad "the bucket's versioning (aws_s3_bucket_versioning) is not in the Terraform state"; exit 1; fi
c_ok "aws_s3_bucket_versioning is in state"

# 5. A plan finds nothing to do.
out=$(terraform -chdir="$TFDIR" plan -detailed-exitcode -input=false -no-color -lock-timeout=5s 2>&1); prc=$?
case $prc in
  0) c_ok "terraform plan: no changes" ;;
  2) c_bad "terraform plan still has changes: the code and the real bucket disagree. $(grep -E '^\s+[~+-/] ' <<<"$out" | head -n 6 | tr -s ' ' | tr '\n' ';')"; exit 1 ;;
  *) c_bad "terraform plan failed: $(tail -n 4 <<<"$out" | tr '\n' ' ')"; exit 1 ;;
esac

# 6. Fixed, but how? ignore_changes = all makes any plan clean.
if cat "$TFDIR"/*.tf | sed -e 's/#.*//' -e 's://.*::' | grep -Eq 'ignore_changes[[:space:]]*=[[:space:]]*(all|\[[[:space:]]*all[[:space:]]*\])'; then
  echo "PENALTY 25 lifecycle { ignore_changes = all } hides the differences instead of fixing the code. The plan is clean because Terraform stopped looking."
fi
c_ok "the hand-made bucket is under Terraform, and nothing in it was touched"
