#!/usr/bin/env bash
# Fixed means: migrate.sh --dry-run -- run here, as the candidate left it -- gets
# a session as the migrator role, and that session either lasts the whole job
# (JOB_SECONDS in the record) or the script refreshes its credentials in time
# (REFRESH_EVERY + one chunk + a minute fits inside the session, and one refresh
# really worked). Penalties: MaxSessionDuration above 4 h "to be safe" (25), a trust
# policy widened to the account root or * (30), the job switched to the lab
# user's long-lived keys instead of a role (20).
# AWS API calls: iam:GetRole, sts:AssumeRole / GetCallerIdentity (via migrate.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
REC="$STATE/drill72.env"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
ACCT=""; ROLE_CI=""; ROLE_MIG=""; JOB_SECONDS=6600
# shellcheck disable=SC1090
source "$REC"
DIR="$WORK/drill72"
[[ -f $DIR/migrate.sh ]] || { c_bad "$DIR/migrate.sh is gone"; exit 1; }

# 1. The migrator role: still there, how long may a session last, who may assume it.
role=$(aws iam get-role --role-name "$ROLE_MIG" --output json 2>&1) \
  || { c_bad "role $ROLE_MIG is gone or unreadable: ${role:0:200}"; exit 1; }
maxs=$(jq -r '.Role.MaxSessionDuration' <<<"$role")
widened=$(jq -r '[.Role.AssumeRolePolicyDocument.Statement | (if type == "array" then . else [.] end)[]
   | select(.Effect == "Allow") | .Principal
   | (if type == "string" then [.] else ([.AWS?] | flatten | map(select(. != null))) end)[]
   | select(. == "*" or endswith(":root"))] | length' <<<"$role")
pen25=no; pen30=no; pen20=no
c_ok "$ROLE_MIG: MaxSessionDuration ${maxs}s"
if (( maxs > 14400 )); then
  pen25=yes; c_warn "MaxSessionDuration is ${maxs}s (more than 4 h): a stolen session now lives that long"
fi
if (( widened > 0 )); then
  pen30=yes; c_warn "the trust policy of $ROLE_MIG allows the account root or *: any principal in the account can assume it"
fi

# 2. Run the job the way it is, dry.
out=$(cd "$DIR" && bash ./migrate.sh --dry-run 2>&1); rc=$?
if (( rc != 0 )); then
  c_bad "migrate.sh --dry-run still fails: $(tail -n 3 <<<"$out" | tr '\n' ' ' | cut -c1-400)"
  if grep -q 'role chaining' <<<"$out"; then
    c_bad "role chaining caps a session at 1 hour, whatever the role's MaxSessionDuration says"
  elif grep -q 'AccessDenied' <<<"$out"; then
    c_bad "AssumeRole was refused: the role's trust policy must name the caller (the lab user, and the ci role if the job chains through it)"
  elif grep -q 'MaxSessionDuration' <<<"$out"; then
    c_bad "the session you ask for is longer than the role's MaxSessionDuration (now ${maxs}s)"
  fi
  exit 1
fi
get() { sed -n "s/^DRYRUN $1=//p" <<<"$out" | head -n 1; }
ident=$(get identity); ss=$(get session_seconds); refresh_every=$(get refresh_every)
chunk=$(get chunk_seconds); refreshed=$(get refresh)
ss=${ss:-0}; refresh_every=${refresh_every:-0}; chunk=${chunk:-300}
[[ $ident == *"assumed-role/$ROLE_MIG/"* || $ident == *":user/"* ]] \
  || { c_bad "the job runs as '${ident:-nothing}', not as the $ROLE_MIG role"; exit 1; }

# 3. Who is the job? A role session, or the lab user's long-lived keys.
if [[ $ident == *":user/"* ]]; then
  pen20=yes; c_warn "the job runs as the IAM user ($ident): long-lived keys never expire, which is exactly the problem"
else
  c_ok "the job runs as $ident"
fi

# 4. Does the credential outlive the job -- or get renewed before it dies?
if [[ $pen20 == yes ]]; then
  :   # long-lived keys: nothing to expire, scored below
elif (( ss >= JOB_SECONDS )); then
  c_ok "the session lasts ${ss}s, the job needs ${JOB_SECONDS}s"
elif (( refresh_every > 0 )) && (( refresh_every + chunk + 60 <= ss )) && [[ $refreshed == ok ]] \
     && (( $(grep -c 'maybe_refresh' "$DIR/migrate.sh") >= 2 )); then
  c_ok "the session lasts ${ss}s, shorter than the job (${JOB_SECONDS}s), but the script re-assumes every ${refresh_every}s (a chunk is ${chunk}s) and a refresh worked"
else
  c_bad "the session lasts ${ss}s but the job needs ${JOB_SECONDS}s, and the script does not refresh in time (REFRESH_EVERY=${refresh_every}, chunk ${chunk}s, refresh: ${refreshed:-none})"
  exit 1
fi

if [[ $pen25 == yes ]]; then
  echo "PENALTY 25 MaxSessionDuration of ${maxs}s: sized 'to be safe' instead of for the job. Allow what the job needs (2 h) or, better, refresh credentials; a long session is a long-lived leak."
fi
if [[ $pen30 == yes ]]; then
  echo "PENALTY 30 The migrator's trust policy was widened to the account root or *. Whoever can assume a role is the whole security model of that role."
fi
if [[ $pen20 == yes ]]; then
  echo "PENALTY 20 The job uses the lab user's long-lived keys instead of a role. It stops the expiry, and trades it for credentials that never rotate and are not scoped to the job."
fi
exit 0
