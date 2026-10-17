#!/usr/bin/env bash
# Fixed means: deploy.sh -- run here, as the candidate left it -- gets through BOTH hops
# (lab user -> CI role -> deploy role), prints the deploy role's assumed-role ARN and lists
# the bucket; AND the deploy role's trust is still tight: Principal exactly the CI role ARN,
# Condition still requiring the recorded ExternalId.
# Penalties (remembered across checks, so fixing afterwards does not wash them away):
#   50 trust widened to an account root / "*"      30 ExternalId condition removed
#   20 permissions added to the CI role (to skip the deploy role)
# AWS API calls: iam:GetRole, ListAttachedRolePolicies, ListRolePolicies; sts:AssumeRole,
# GetCallerIdentity and s3:ListObjectsV2 via deploy.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
REC="$STATE/drill68.env"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
CI=""; DEPLOY=""; BUCKET=""; EXTID=""; ME_ARN=""
# shellcheck disable=SC1090
source "$REC"
DIR="$WORK/drill68"
acct=$(aws_account)
CI_ARN="arn:aws:iam::$acct:role/$CI"
[[ -f $DIR/deploy.sh ]] || { c_bad "$DIR/deploy.sh is gone"; exit 1; }

trust=$(aws iam get-role --role-name "$DEPLOY" --query Role.AssumeRolePolicyDocument --output json 2>&1) \
  || { c_bad "cannot read role $DEPLOY (deleted?): ${trust:0:200}"; exit 1; }
STM='.Statement | (if type == "array" then . else [.] end)[] | select(.Effect == "Allow")'
principals=$(jq -r "[$STM | .Principal | (if type == \"string\" then [.] else [.AWS?] | flatten | map(select(. != null)) end) | .[]] | sort | join(\" \")" <<<"$trust")
extids=$(jq -r "[$STM | .Condition.StringEquals[\"sts:ExternalId\"]? | select(. != null)] | flatten | join(\" \")" <<<"$trust")

# 1. The trust policy: still tight?
T50="$STATE/drill68.tamper-widened"; T30="$STATE/drill68.tamper-extid"; T20="$STATE/drill68.tamper-ci"
trust_ok=yes; msg=""
if [[ " $principals " == *' * '* || $principals == *':root'* ]]; then
  trust_ok=no; echo "trust widened to: $principals" > "$T50"
  msg="the deploy role trusts $principals: anyone in the account (or everyone) may assume it"
elif [[ $principals != "$CI_ARN" ]]; then
  trust_ok=no
  if [[ $principals == *"$ME_ARN"* ]]; then msg="the deploy role trusts the lab user directly ($principals): CI must come in through the CI role, and only through it"
  else msg="the deploy role trusts '${principals:-nobody}', not the CI role ($CI_ARN)"; fi
fi
if [[ " $extids " != *" $EXTID "* ]]; then
  trust_ok=no; echo "ExternalId condition removed or changed" > "$T30"
  msg="${msg:+$msg; }the trust no longer requires sts:ExternalId = the value from the security ticket"
fi
if [[ $trust_ok == no ]]; then
  c_bad "deploy role trust: $msg"
else
  c_ok "deploy role trust: Principal is exactly the CI role, and sts:ExternalId is still required"
fi

# 2. Was the CI role given permissions of its own?
n_att=$(aws iam list-attached-role-policies --role-name "$CI" --query 'length(AttachedPolicies)' --output text 2>/dev/null || echo 0)
n_inl=$(aws iam list-role-policies --role-name "$CI" --query 'length(PolicyNames)' --output text 2>/dev/null || echo 0)
if [[ ${n_att:-0} != 0 || ${n_inl:-0} != 0 ]]; then
  echo "permissions added to the CI role" > "$T20"
  c_warn "the CI role now carries permissions of its own ($n_att attached, $n_inl inline)"
fi
[[ $trust_ok == yes ]] || exit 1

# 3. Run the deploy step as the candidate left it (IAM changes can take a few seconds).
out=""; rc=1
for _ in 1 2 3 4; do
  out=$(cd "$DIR" && bash ./deploy.sh 2>&1); rc=$?
  (( rc == 0 )) && break
  sleep 5
done
if (( rc != 0 )); then
  c_bad "deploy.sh still fails: $(tail -n 3 <<<"$out" | tr '\n' ' ' | cut -c1-500)"
  if grep -q 'AccessDenied' <<<"$out" && grep -q 'sts:AssumeRole' <<<"$out"; then
    c_bad "an sts:AssumeRole was refused: compare WHO is calling and WHAT the request carries with the role's trust policy (principal, conditions)"
  fi
  exit 1
fi
if ! grep -q "assumed-role/$DEPLOY/" <<<"$out"; then
  c_bad "deploy.sh worked, but not AS the deploy role (it should print an assumed-role/$DEPLOY/... ARN)"; exit 1
fi
grep -q 'deploy/manifest.txt' <<<"$out" || { c_bad "deploy.sh did not list the bucket contents"; exit 1; }
c_ok "deploy.sh ran as: $(grep '^deploying as:' <<<"$out" | sed 's/^deploying as: //')"
c_ok "bucket listing works: $(tail -n 1 <<<"$out")"

[[ -f $T50 ]] && echo "PENALTY 50 The deploy role's trust was widened ($(cat "$T50")). Opening it up makes the error go away and removes the whole point of the review: only the CI role may assume it."
[[ -f $T30 ]] && echo "PENALTY 30 The ExternalId condition was removed. It is what protects the role from a confused deputy; the fix is to SEND the ExternalId, not to stop requiring it."
[[ -f $T20 ]] && echo "PENALTY 20 Permissions were added to the CI role to get around the deploy role. The CI role is deliberately powerless; the deploy role holds the access."
exit 0
