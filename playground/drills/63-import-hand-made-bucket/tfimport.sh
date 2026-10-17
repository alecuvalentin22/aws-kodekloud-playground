# shellcheck shell=bash
# Shared by break.sh / check.sh / reset.sh of drill 63. Source it AFTER
# lib/common.sh + lib/aws.sh (and aws_env). Nothing here runs by itself.
#
# The drill owns ONE Terraform root, $WORK/tf-import, whose state lives in the lab's
# state bucket under its own key prefix, and ONE hand-made S3 bucket named
# platform-lab-drill63-<account>-<rand> tagged platform-lab-drill=63.
# Everything reset.sh acts on is recorded in $REC by break.sh.
TFDIR="$WORK/tf-import"
TF_PREFIX="platform-lab/playground/import-drill/"
TF_KEY="${TF_PREFIX}terraform.tfstate"
REC="$STATE/drill63.env"
TF_REGION="${AWS_REGION:-us-east-1}"
BUCKET_PREFIX="platform-lab-drill63-"

# The lab's state bucket: <prefix>-tfstate-<account id> (terraform/bootstrap).
tf_bucket() {
  local b
  b="andrei-lab-tfstate-$(aws_account)"
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then echo "$b"; return 0; fi
  b=$(terraform -chdir="$LAB_ROOT/terraform/bootstrap" output -raw state_bucket 2>/dev/null || true)
  if [[ -n $b ]] && aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then echo "$b"; return 0; fi
  return 1
}

# Delete EVERY version and delete marker under a prefix ("" = the whole bucket).
s3_purge() {   # s3_purge BUCKET PREFIX
  local json n
  while :; do
    json=$(aws s3api list-object-versions --bucket "$1" --prefix "$2" --max-items 500 --output json 2>/dev/null) || return 0
    n=$(jq '[(.Versions // [])[], (.DeleteMarkers // [])[]] | length' <<<"$json")
    [[ $n -gt 0 ]] || return 0
    jq -c '{Objects: [(.Versions // [])[], (.DeleteMarkers // [])[] | {Key, VersionId}], Quiet: true}' <<<"$json" > "$STATE/.purge.json"
    aws s3api delete-objects --bucket "$1" --delete "file://$STATE/.purge.json" >/dev/null || return 1
  done
}

bucket_created() {   # bucket_created NAME -> CreationDate, empty when the bucket is not in the account
  aws s3api list-buckets --query "Buckets[?Name=='$1'].CreationDate | [0]" --output text 2>/dev/null | grep -v '^None$' || true
}

# Sorted key=value tags of a bucket, one line.
bucket_tags() {   # bucket_tags NAME
  aws s3api get-bucket-tagging --bucket "$1" --output json 2>/dev/null \
    | jq -r '[.TagSet[] | "\(.Key)=\(.Value)"] | sort | join(",")' 2>/dev/null || true
}

sha_of_key() {   # sha_of_key BUCKET KEY -> sha256 of the CURRENT object body
  local tmp; tmp=$(mktemp)
  if aws s3api get-object --bucket "$1" --key "$2" "$tmp" >/dev/null 2>&1; then
    shasum -a 256 "$tmp" | cut -d' ' -f1
  fi
  rm -f "$tmp"
}
