#!/usr/bin/env bash
# Deletes EVERY object version and delete marker in the bucket break.sh recorded in
# "$STATE/drill62.env", then the bucket. Acts ONLY on that record: with no record it
# does nothing (another lane's `play reset` runs every AWS drill's reset.sh with a
# different STATE, and must not touch this drill's bucket). Refuses a bucket that is
# not named platform-lab-drill62-* and tagged platform-lab-drill=62.
# AWS API calls: s3:GetBucketTagging, ListObjectVersions, DeleteObject(+Version), DeleteBucket.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"
REC="$STATE/drill62.env"
[[ -f $REC ]] || exit 0
[[ -r $AWS_CREDS_FILE ]] || exit 0
aws_env
BUCKET=$(sed -n 's/^BUCKET=//p' "$REC" | head -1)
[[ $BUCKET == platform-lab-drill62-* ]] || { rm -f "$REC"; exit 0; }
if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  # Already gone (or credentials expired: then we must not forget the record).
  aws sts get-caller-identity >/dev/null 2>&1 || { echo "reset drill 62: AWS credentials rejected; bucket $BUCKET left, record kept" >&2; exit 0; }
  rm -f "$REC" "$STATE/drill62.suspended"; exit 0
fi
tag=$(aws s3api get-bucket-tagging --bucket "$BUCKET" --query "TagSet[?Key=='platform-lab-drill'].Value | [0]" --output text 2>/dev/null)
[[ $tag == 62 ]] || { echo "reset drill 62: $BUCKET is not tagged platform-lab-drill=62; refusing to touch it" >&2; exit 0; }

n=0
while (( n < 20 )); do
  n=$((n + 1))
  payload=$(aws s3api list-object-versions --bucket "$BUCKET" --max-items 500 --output json 2>/dev/null \
    | jq -c '{Objects: [((.Versions // [])[], (.DeleteMarkers // [])[]) | {Key, VersionId}], Quiet: true}')
  [[ -n $payload && $(jq '.Objects | length' <<<"$payload") -gt 0 ]] || break
  aws s3api delete-objects --bucket "$BUCKET" --delete "$payload" >/dev/null 2>&1 || {
    # Fall back to one by one if the bulk call is refused.
    jq -r '.Objects[] | [.Key, .VersionId] | @tsv' <<<"$payload" | while IFS=$'\t' read -r k v; do
      aws s3api delete-object --bucket "$BUCKET" --key "$k" --version-id "$v" >/dev/null 2>&1 || true
    done; }
done
if aws s3api delete-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  rm -f "$REC" "$STATE/drill62.suspended"
else
  echo "reset drill 62: could not delete $BUCKET (not empty?); record kept, re-run reset" >&2
fi
exit 0
