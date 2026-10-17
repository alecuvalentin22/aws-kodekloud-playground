#!/usr/bin/env bash
# Deletes what break.sh recorded in $STATE/drill72.env -- the two roles
# platform-lab-drill72-ci and platform-lab-drill72-migrator (policies detached
# first) and the workspace -- and nothing else. No record, no action: other
# lanes' `play reset` runs this against a state dir where drill 72 never
# started. Skipped silently without AWS credentials.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"
REC="$STATE/drill72.env"
[[ -f $REC ]] || exit 0
[[ -r $AWS_CREDS_FILE ]] || exit 0
aws_env
ROLE_CI=""; ROLE_MIG=""
# shellcheck disable=SC1090
source "$REC"
rm -rf "$WORK/drill72"
left=0
for r in "$ROLE_MIG" "$ROLE_CI"; do
  [[ $r == platform-lab-drill72-* ]] || continue     # never touch a role this drill did not name
  rc=0; out=$(aws iam get-role --role-name "$r" 2>&1) || rc=$?
  if (( rc != 0 )); then
    grep -q 'NoSuchEntity' <<<"$out" && continue
    c_warn "drill 72: cannot read role $r (${out:0:120}); record kept, run reset again"; left=1; continue
  fi
  for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$r" --policy-arn "$p" >/dev/null 2>&1 || true
  done
  for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$r" --policy-name "$p" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$r" >/dev/null 2>&1 \
    || { c_warn "drill 72: could not delete role $r; record kept, run reset again"; left=1; }
done
(( left )) || rm -f "$REC"
exit 0
