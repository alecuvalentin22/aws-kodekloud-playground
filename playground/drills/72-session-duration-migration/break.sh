#!/usr/bin/env bash
# A 2-hour migration job and a 1-hour STS session.
#
# Creates TWO IAM roles (no policies attached: the job's only API call is
# sts:GetCallerIdentity, which needs no permission):
#   platform-lab-drill72-ci        trust: the lab user                 (the pipeline's role)
#   platform-lab-drill72-migrator  trust: the lab user + the ci role   MaxSessionDuration 3600
# and a workspace ~/platform-playground-aws/drill72 whose migrate.sh first
# assumes the ci role and then CHAINS into the migrator role asking for
# 7200 s. Layer 1: the migrator's MaxSessionDuration is 3600 (ValidationError).
# Layer 2 (after raising it): role chaining is capped at 3600 whatever the
# role allows.
#
# Everything it creates is recorded in $STATE/drill72.env BEFORE it is created;
# reset.sh acts ONLY on that record.
#
# AWS API calls: sts:GetCallerIdentity, iam:CreateRole (x2), sts:AssumeRole (probes).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
mkdir -p "$STATE/logs"
REC="$STATE/drill72.env"
DIR="$WORK/drill72"

# An earlier run of this drill in THIS state dir: clean it up first.
[[ -f $REC ]] && bash "$HERE/reset.sh"

acct=$(aws_account)
user_arn=$(aws sts get-caller-identity --query Arn --output text)
ROLE_CI=platform-lab-drill72-ci
ROLE_MIG=platform-lab-drill72-migrator
umask 077
# Recorded first: whatever happens next, reset knows what to look for.
printf 'ACCT=%s\nROLE_CI=%s\nROLE_MIG=%s\nJOB_SECONDS=6600\n' "$acct" "$ROLE_CI" "$ROLE_MIG" > "$REC"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/ci-trust.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"$user_arn"},"Action":"sts:AssumeRole"}]}
JSON
aws iam create-role --role-name "$ROLE_CI" --path / \
  --description "platform-lab drill 72: the pipeline's role" \
  --assume-role-policy-document "file://$TMP/ci-trust.json" \
  --tags Key=platform-lab-drill,Value=72 >/dev/null

# The migrator trusts the lab user AND the ci role. The principal must exist when
# the trust policy is written, and IAM is eventually consistent: retry a little.
cat > "$TMP/mig-trust.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["$user_arn","arn:aws:iam::$acct:role/$ROLE_CI"]},"Action":"sts:AssumeRole"}]}
JSON
ok=no
for _ in $(seq 1 15); do
  if aws iam create-role --role-name "$ROLE_MIG" --path / --max-session-duration 3600 \
       --description "platform-lab drill 72: the data migration role" \
       --assume-role-policy-document "file://$TMP/mig-trust.json" \
       --tags Key=platform-lab-drill,Value=72 >/dev/null 2>"$TMP/err"; then ok=yes; break; fi
  grep -q 'EntityAlreadyExists' "$TMP/err" && { ok=yes; break; }
  sleep 3
done
[[ $ok == yes ]] || { cat "$TMP/err" >&2; exit 1; }

# --- the workspace ------------------------------------------------------------
rm -rf "$DIR"; mkdir -p "$DIR"
cat > "$DIR/aws-env.sh" <<ENV
# Lab credentials into THIS shell (never into ~/.aws):   . ./aws-env.sh
set -a; . "$AWS_CREDS_FILE"; set +a
unset AWS_PROFILE
export AWS_DEFAULT_REGION=us-east-1 AWS_REGION=us-east-1
ENV
cat > "$DIR/job.env" <<ENV
# Settings of the nightly data migration (owner: data-eng)
CI_ROLE=$ROLE_CI                 # the pipeline's role (VIA_CI=yes: assume this first)
ROLE=$ROLE_MIG        # the role the migration runs as
VIA_CI=yes                       # yes: ci role first, then the migrator from inside it
SESSION_SECONDS=7200             # --duration-seconds for the migrator session ("the job takes ~2 h")
REFRESH_EVERY=0                  # seconds between credential refreshes; 0 = never refresh
CHUNK_SECONDS=\${CHUNK_SECONDS:-300}   # the job works in chunks this long
ENV
cat > "$DIR/README.md" <<'MD'
# Nightly data migration (drill 72)

`./migrate.sh`            runs the migration (chunks of CHUNK_SECONDS; `CHUNK_SECONDS=1 ./migrate.sh`, Ctrl-C when you have seen enough)
`./migrate.sh --dry-run`  only gets the session and prints what it would run with. No migration.

The job needs valid credentials for its whole run (about 110 minutes).
Every chunk calls AWS (here: sts get-caller-identity stands in for the real copy).

Credential refresh: `migrate.sh` calls `maybe_refresh` before every chunk. It
re-assumes the role when REFRESH_EVERY seconds have passed since the last
assume (0 = never). `--dry-run` proves a refresh works by doing one.
Settings live in job.env. Lab credentials: `. ./aws-env.sh`
MD
cat > "$DIR/migrate.sh" <<'SH'
#!/usr/bin/env bash
# Nightly data migration. usage: ./migrate.sh [--dry-run]
set -euo pipefail
cd "$(dirname "$0")"
. ./job.env
JOB_SECONDS=6600                       # how long the migration really runs (about 110 min)
DRY=no; [[ ${1:-} == --dry-run ]] && DRY=yes
ACCT=$(. ./aws-env.sh; aws sts get-caller-identity --query Account --output text)

# One fresh session for ROLE, from the lab user's keys. Prints:  KEY SECRET TOKEN EXPIRATION
assume() {   # assume <role-name> <seconds>
  aws sts assume-role --role-arn "arn:aws:iam::$ACCT:role/$1" \
    --role-session-name "migrate-$(date +%s)" --duration-seconds "$2" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken,Expiration]' --output text
}
get_session() {
  local c ak sk st exp
  c=$(
    . ./aws-env.sh; unset AWS_SESSION_TOKEN        # always start from the lab user, never from an old session
    if [[ $VIA_CI == yes ]]; then
      c=$(assume "$CI_ROLE" 3600) || exit 1
      read -r ak sk st _ <<<"$c"
      AWS_ACCESS_KEY_ID=$ak AWS_SECRET_ACCESS_KEY=$sk AWS_SESSION_TOKEN=$st assume "$ROLE" "$SESSION_SECONDS" \
        || exit 1
    else
      assume "$ROLE" "$SESSION_SECONDS" || exit 1
    fi
  ) || return 1
  read -r ak sk st exp <<<"$c"
  export AWS_ACCESS_KEY_ID=$ak AWS_SECRET_ACCESS_KEY=$sk AWS_SESSION_TOKEN=$st
  SESSION_STARTED=$(date +%s)
  SESSION_LEFT=$(python3 -c 'import sys,datetime as d;print(int(d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()-d.datetime.now().timestamp()))' "$exp")
}
maybe_refresh() {
  (( REFRESH_EVERY > 0 )) || return 0
  (( $(date +%s) - SESSION_STARTED >= REFRESH_EVERY )) || return 0
  echo "refreshing credentials ($ROLE)"
  get_session
}

get_session
IDENTITY=$(aws sts get-caller-identity --query Arn --output text)
echo "assumed: $IDENTITY (session valid for ${SESSION_LEFT}s)"

if [[ $DRY == yes ]]; then
  REFRESHED=skipped
  if (( REFRESH_EVERY > 0 )); then get_session && REFRESHED=ok || REFRESHED=failed; fi
  echo "DRYRUN identity=$IDENTITY"
  echo "DRYRUN session_seconds=$SESSION_LEFT"
  echo "DRYRUN job_seconds=$JOB_SECONDS"
  echo "DRYRUN refresh_every=$REFRESH_EVERY"
  echo "DRYRUN chunk_seconds=$CHUNK_SECONDS"
  echo "DRYRUN refresh=$REFRESHED"
  exit 0
fi

T0=$(date +%s)
N=$(( JOB_SECONDS / CHUNK_SECONDS ))
for i in $(seq 1 "$N"); do
  maybe_refresh
  aws sts get-caller-identity --query Arn --output text >/dev/null   # stand-in for the real copy
  echo "chunk $i/$N ok (+$(( $(date +%s) - T0 ))s)"
  sleep "$CHUNK_SECONDS"
done
echo "migration complete"
SH
chmod +x "$DIR/migrate.sh"

# IAM is eventually consistent: wait until the job fails the way the ticket says
# (and fail the break if it never does: then the drill would be a no-op).
for _ in $(seq 1 25); do
  if ! bash "$DIR/migrate.sh" --dry-run >"$STATE/logs/drill72-probe.log" 2>&1; then
    grep -q 'MaxSessionDuration' "$STATE/logs/drill72-probe.log" && exit 0
  fi
  sleep 3
done
echo "the probe never failed with the MaxSessionDuration error: $(cat "$STATE/logs/drill72-probe.log")" >&2
exit 1
