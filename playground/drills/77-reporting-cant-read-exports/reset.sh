#!/usr/bin/env bash
# Deletes what break.sh recorded in $STATE/drill77.env -- the role (policies
# detached first), the bucket (emptied first, tag-checked) and the workspace -- and
# nothing else. No record, no action. Skipped silently without AWS credentials.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"
REC="$STATE/drill77.env"
[[ -f $REC ]] || exit 0
[[ -r $AWS_CREDS_FILE ]] || exit 0
aws_env
ROLE=""; BUCKET=""
# shellcheck disable=SC1090
source "$REC"
left=0
rm -rf "$WORK/drill77"
if [[ $ROLE == platform-lab-drill77-* ]]; then
  rc=0; out=$(aws iam get-role --role-name "$ROLE" 2>&1) || rc=$?
  if (( rc != 0 )); then
    grep -q NoSuchEntity <<<"$out" || { c_warn "drill 77: cannot read role $ROLE (${out:0:120})"; left=1; }
  else
    for p in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$p" >/dev/null 2>&1 || true
    done
    for n in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames' --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$ROLE" --policy-name "$n" >/dev/null 2>&1 || true
    done
    aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 \
      || { c_warn "drill 77: could not delete role $ROLE"; left=1; }
  fi
fi
if [[ $BUCKET == platform-lab-drill77-* ]]; then
  rc=0; out=$(aws s3api get-bucket-tagging --bucket "$BUCKET" --query "TagSet[?Key=='platform-lab-drill'].Value" --output text 2>&1) || rc=$?
  if (( rc != 0 )) && grep -Eq 'NoSuchBucket|404' <<<"$out"; then
    :
  elif (( rc != 0 )); then
    c_warn "drill 77: cannot read the tags of $BUCKET (${out:0:120})"; left=1
  elif [[ $out != 77 ]]; then
    c_warn "drill 77: $BUCKET does not carry platform-lab-drill=77; not touching it"
  else
    aws s3api delete-bucket-policy --bucket "$BUCKET" >/dev/null 2>&1 || true
    aws s3 rm "s3://$BUCKET" --recursive >/dev/null 2>&1 || true
    aws s3api delete-bucket --bucket "$BUCKET" >/dev/null 2>&1 \
      || { c_warn "drill 77: could not delete $BUCKET"; left=1; }
  fi
fi
if (( left )); then c_warn "drill 77: something is left; record kept, run reset again"; exit 0; fi
rm -f "$REC" "$STATE"/drill77.tamper-* "$STATE/drill77.fetch.orig"
exit 0
