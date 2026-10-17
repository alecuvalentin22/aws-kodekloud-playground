#!/usr/bin/env bash
# Fixed means: fetch.sh -- run here, as the candidate left it -- lists and downloads
# exports/ AND still reads reports/, AS the reporting role; and the live bucket policy
# grants that role only the reports/ and exports/ prefixes (ListBucket narrowed by
# s3:prefix on the bucket ARN, GetObject on the two object-path ARNs).
# Penalties (remembered across checks, so fixing afterwards does not wash them away):
#   40 bucket/*, s3:*, s3:Get* or Principal "*" without aws:PrincipalArn (or managed
#      policy added to the role)    20 ListBucket granted without an s3:prefix condition
#   15 files copied into reports/ instead of fixing access
# AWS API calls: iam:ListAttachedRolePolicies, ListRolePolicies; s3:GetBucketPolicy,
# ListObjectsV2 (lab user, reports/ only); sts:AssumeRole/ListObjectsV2/GetObject via fetch.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
REC="$STATE/drill77.env"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
ROLE=""; BUCKET=""
# shellcheck disable=SC1090
source "$REC"
DIR="$WORK/drill77"
acct=$(aws_account)
ROLE_ARN="arn:aws:iam::$acct:role/$ROLE"
[[ -f $DIR/fetch.sh ]] || { c_bad "$DIR/fetch.sh is gone"; exit 1; }
T40="$STATE/drill77.tamper-broad"; T20="$STATE/drill77.tamper-noprefix"; T15="$STATE/drill77.tamper-copied"

# 1. Files copied into reports/ ?
extra=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix reports/ --query 'Contents[].Key' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' | grep -vx 'reports/2026-09.csv' | head -3 | tr '\n' ' ')
if [[ -n ${extra// /} ]]; then
  echo "objects added under reports/: $extra" > "$T15"
  c_warn "there are new objects under reports/ ($extra): the exports were copied instead of granting access"
fi

# 2. The role itself: no policies of its own.
n_att=$(aws iam list-attached-role-policies --role-name "$ROLE" --query 'length(AttachedPolicies)' --output text 2>/dev/null || echo 0)
n_inl=$(aws iam list-role-policies --role-name "$ROLE" --query 'length(PolicyNames)' --output text 2>/dev/null || echo 0)
if [[ ${n_att:-0} != 0 || ${n_inl:-0} != 0 ]]; then
  echo "policies attached to the role" > "$T40"
  c_warn "the reporting role now carries identity policies ($n_att attached, $n_inl inline): the grant belongs in the bucket policy, scoped per prefix"
fi

# 3. The live bucket policy.
live=$(aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text 2>&1) \
  || { c_bad "cannot read the bucket policy (deleted?): ${live:0:200}"; exit 1; }
verdict=$(jq -c --arg role "$ROLE_ARN" --arg b "$BUCKET" '
  def arr: if type == "array" then . else [.] end;
  def cv($k): [ (.Condition // {}) | to_entries[] | .value | to_entries[] | select(.key == $k) | .value | arr[] ];
  def pall: (.Principal == "*") or (.Principal | type == "object" and ((.Principal.AWS // []) | arr | index("*") != null));
  def prole: (.Principal | type == "object" and ((.Principal.AWS // []) | arr | index($role) != null));
  def pcond: (cv("aws:PrincipalArn") | index($role)) != null;
  [ .Statement | arr[] | select(.Effect == "Allow") | select(prole or (pall and pcond) or (pall and ((cv("aws:PrincipalArn") | length) == 0)))
    | {acts: (.Action | arr), res: (.Resource | arr), pre: cv("s3:prefix"), wild: (pall and (pcond | not))} ] as $s
  | ("arn:aws:s3:::" + $b) as $B
  | { broad: ([$s[] | select(.wild or ([.acts[] | test("^(s3:)?\\*$|^s3:Get\\*$")] | any)
                              or ([.res[] | . == "*" or . == "arn:aws:s3:::*" or . == ($B + "/*") or . == ($B + "*")] | any))] | length > 0),
      noprefix: ([$s[] | select([.acts[] | test("^(s3:)?\\*$|^s3:ListBucket$|^s3:List\\*$")] | any) | select(.pre | length == 0)] | length > 0),
      badscope: (([$s[] | select([.acts[] | test("^s3:ListBucket$")] | any) | .pre[] | select(test("^(reports|exports)/") | not)] | length > 0)
             or ([$s[] | select([.acts[] | test("^s3:GetObject$")] | any) | .res[] | select((startswith($B + "/reports/") or startswith($B + "/exports/")) | not)] | length > 0)) }
' <<<"$live" 2>/dev/null)
[[ -n $verdict ]] || { c_bad "could not parse the bucket policy"; exit 1; }
broad=$(jq -r .broad <<<"$verdict"); nopre=$(jq -r .noprefix <<<"$verdict"); badscope=$(jq -r .badscope <<<"$verdict")
[[ $broad == true ]] && { echo "broad grant in the bucket policy" > "$T40"; c_bad "the bucket policy grants more than reports/ and exports/ (bucket/*, s3:*, or Principal \"*\" without the aws:PrincipalArn condition)"; }
[[ $nopre == true ]] && { echo "ListBucket without s3:prefix" > "$T20"; c_bad "s3:ListBucket is granted without an s3:prefix condition: the role could list the WHOLE bucket"; }
if [[ $broad != true && $nopre != true && $badscope == true ]]; then
  c_bad "the bucket policy grants a prefix other than reports/ and exports/"
fi
policy_ok=yes
[[ $broad == true || $nopre == true || $badscope == true ]] && policy_ok=no
[[ $policy_ok == yes ]] && c_ok "bucket policy: only the reports/ and exports/ prefixes are granted to the role"

# 4. Run the job, as it is, for both prefixes (policy changes can take a few seconds).
run() { local o rc=1 i; for i in 1 2 3 4; do o=$(cd "$DIR" && bash ./fetch.sh "$1" 2>&1); rc=$?; (( rc == 0 )) && break; sleep 5; done; echo "$o"; return $rc; }
ex=$(run exports/); rc=$?
if (( rc != 0 )); then
  c_bad "fetch.sh (exports/) still fails: $(tail -n 3 <<<"$ex" | tr '\n' ' ' | cut -c1-500)"
  if grep -q 'ListObjectsV2' <<<"$ex"; then c_bad "the LIST was refused: ListBucket is a bucket-level action; look at the s3:prefix condition of its statement"
  elif grep -q 'GetObject' <<<"$ex"; then c_bad "the listing works but the DOWNLOAD was refused: GetObject is an object-level action; look at the Resource ARN of its statement"; fi
  exit 1
fi
grep -q "assumed-role/$ROLE/" <<<"$ex" || { c_bad "fetch.sh worked, but not AS the reporting role (it should print assumed-role/$ROLE/...)"; exit 1; }
grep -q 'downloaded exports/2026-10.csv' <<<"$ex" || { c_bad "fetch.sh did not download exports/2026-10.csv"; exit 1; }
c_ok "exports/: $(grep -c '^downloaded' <<<"$ex") file(s) listed and downloaded as the reporting role"
rp=$(run reports/); rc=$?
if (( rc != 0 )) || ! grep -q 'downloaded reports/2026-09.csv' <<<"$rp"; then
  c_bad "reports/ no longer works (the old access must stay): $(tail -n 2 <<<"$rp" | tr '\n' ' ' | cut -c1-300)"; exit 1
fi
c_ok "reports/ still works"
[[ $policy_ok == yes ]] || exit 1

[[ -f $T40 ]] && echo "PENALTY 40 Access was widened ($(cat "$T40")). Broad grants make AccessDenied go away and expose everything the bucket will hold later: the grant is per prefix, with ListBucket on the bucket ARN narrowed by s3:prefix and GetObject on the two object paths."
[[ -f $T20 ]] && echo "PENALTY 20 s3:ListBucket was granted without an s3:prefix condition: the role could list every key in the bucket, not just reports/ and exports/."
[[ -f $T15 ]] && echo "PENALTY 15 The files were copied into reports/ instead of fixing access ($(cat "$T15")). The symptom goes away, but the data team's layout is broken and the next prefix fails the same way."
exit 0
