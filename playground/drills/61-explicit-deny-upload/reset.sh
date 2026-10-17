#!/usr/bin/env bash
# Deletes what break.sh recorded in $STATE/drill61.env -- the bucket (emptied
# first, after confirming it carries the drill's tag and name prefix) and the
# workspace -- and nothing else. No record, no action: other lanes' `play reset`
# runs this against a state dir where drill 61 never started. Skipped silently
# without AWS credentials, so a local `play reset` never fails here.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"
REC="$STATE/drill61.env"
[[ -f $REC ]] || exit 0
[[ -r $AWS_CREDS_FILE ]] || exit 0
aws_env
BUCKET=""; POLICY=""
# shellcheck disable=SC1090
source "$REC"
rm -rf "$WORK/drill61"
if [[ $BUCKET == platform-lab-drill61-* ]]; then
  rc=0; out=$(aws s3api get-bucket-tagging --bucket "$BUCKET" --query "TagSet[?Key=='platform-lab-drill'].Value" --output text 2>&1) || rc=$?
  if (( rc != 0 )) && grep -Eq 'NoSuchBucket|404' <<<"$out"; then
    :   # already gone
  elif (( rc != 0 )); then
    c_warn "drill 61: cannot read the tags of $BUCKET (${out:0:120}); record kept, run reset again"; exit 0
  elif [[ $out != 61 ]]; then
    c_warn "drill 61: $BUCKET does not carry platform-lab-drill=61; not touching it"
  else
    aws s3api delete-bucket-policy --bucket "$BUCKET" >/dev/null 2>&1 || true
    aws s3 rm "s3://$BUCKET" --recursive >/dev/null 2>&1 || true
    aws s3api delete-bucket --bucket "$BUCKET" >/dev/null 2>&1 \
      || { c_warn "drill 61: could not delete $BUCKET; record kept, run reset again"; exit 0; }
  fi
fi
rm -f "$REC" "${POLICY:-}" "$STATE/drill61.policy.json" "$STATE/drill61.upload.orig" "$STATE/drill61.tampered"
exit 0
