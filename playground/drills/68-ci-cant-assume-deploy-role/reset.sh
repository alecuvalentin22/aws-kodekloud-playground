#!/usr/bin/env bash
# Deletes what break.sh recorded in $STATE/drill68.env -- three roles (policies
# detached first), the bucket (emptied first, tag-checked) and the workspace -- and
# nothing else. No record, no action. Skipped silently without AWS credentials.
# (break.sh creates no managed policy: DeletePolicy is denied on this account.)
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"
REC="$STATE/drill68.env"
[[ -f $REC ]] || exit 0
[[ -r $AWS_CREDS_FILE ]] || exit 0
aws_env
CI=""; LEGACY=""; DEPLOY=""; BUCKET=""
# shellcheck disable=SC1090
source "$REC"
left=0
rm -rf "$WORK/drill68"
for role in "$DEPLOY" "$CI" "$LEGACY"; do
  [[ $role == platform-lab-drill68-* ]] || continue
  rc=0; out=$(aws iam get-role --role-name "$role" 2>&1) || rc=$?
  if (( rc != 0 )); then
    grep -q NoSuchEntity <<<"$out" && continue
    c_warn "drill 68: cannot read role $role (${out:0:120})"; left=1; continue
  fi
  for p in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$p" >/dev/null 2>&1 || true
  done
  for n in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$n" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$role" >/dev/null 2>&1 \
    || { c_warn "drill 68: could not delete role $role"; left=1; }
done
if [[ $BUCKET == platform-lab-drill68-* ]]; then
  rc=0; out=$(aws s3api get-bucket-tagging --bucket "$BUCKET" --query "TagSet[?Key=='platform-lab-drill'].Value" --output text 2>&1) || rc=$?
  if (( rc != 0 )) && grep -Eq 'NoSuchBucket|404' <<<"$out"; then
    :   # already gone
  elif (( rc != 0 )); then
    c_warn "drill 68: cannot read the tags of $BUCKET (${out:0:120})"; left=1
  elif [[ $out != 68 ]]; then
    c_warn "drill 68: $BUCKET does not carry platform-lab-drill=68; not touching it"
  else
    aws s3api delete-bucket-policy --bucket "$BUCKET" >/dev/null 2>&1 || true
    aws s3 rm "s3://$BUCKET" --recursive >/dev/null 2>&1 || true
    aws s3api delete-bucket --bucket "$BUCKET" >/dev/null 2>&1 \
      || { c_warn "drill 68: could not delete $BUCKET"; left=1; }
  fi
fi
if (( left )); then c_warn "drill 68: something is left; record kept, run reset again"; exit 0; fi
rm -f "$REC" "$STATE"/drill68.tamper-* "$STATE/drill68.deploy.orig"
exit 0
