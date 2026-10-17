#!/usr/bin/env bash
# A 2019 wiki one-liner meets a 2023+ bucket.
#
# Creates ONE small S3 bucket (platform-lab-drill75-<account>-<rand>, tagged
# platform-lab-drill=75) with the DEFAULTS of a new bucket: Object Ownership =
# BucketOwnerEnforced (ACLs disabled), block public access all on. The workspace
# has publish.sh, which syncs ./assets with `--acl public-read`, copied from an
# old wiki page. The ACL makes S3 answer AccessControlListNotSupported.
#
# Everything it creates is recorded in $STATE/drill75.env (written before the
# bucket is created); reset.sh acts ONLY on that record.
#
# AWS API calls: sts:GetCallerIdentity, s3:CreateBucket, PutBucketPublicAccessBlock,
# PutBucketTagging, GetBucketOwnershipControls, PutObject (one probe, expected to fail).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
mkdir -p "$STATE/logs"
REC="$STATE/drill75.env"
DIR="$WORK/drill75"

# An earlier run of this drill in THIS state dir: clean it up first.
[[ -f $REC ]] && bash "$HERE/reset.sh"

acct=$(aws_account)
BUCKET="platform-lab-drill75-$acct-$(printf '%04x%04x' $RANDOM $RANDOM)"
# Record first, create second: reset can then always find what a half-failed break made.
umask 077
printf 'BUCKET=%s\n' "$BUCKET" > "$REC"
aws s3api create-bucket --bucket "$BUCKET" --region us-east-1 >/dev/null
aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging 'TagSet=[{Key=platform-lab-drill,Value=75},{Key=owner,Value=platform-team}]'
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# A brand-new bucket is BucketOwnerEnforced by default; fail the break if it is not
# (then the drill would not reproduce).
own=$(aws s3api get-bucket-ownership-controls --bucket "$BUCKET" \
        --query 'OwnershipControls.Rules[0].ObjectOwnership' --output text 2>&1 || true)
[[ $own == BucketOwnerEnforced ]] || { echo "new bucket is not BucketOwnerEnforced: $own" >&2; exit 1; }

# --- the workspace ------------------------------------------------------------
rm -rf "$DIR"; mkdir -p "$DIR/assets"
cat > "$DIR/aws-env.sh" <<ENV
# Lab credentials into THIS shell (never into ~/.aws):   . ./aws-env.sh
set -a; . "$AWS_CREDS_FILE"; set +a
unset AWS_PROFILE
export AWS_DEFAULT_REGION=us-east-1 AWS_REGION=us-east-1
ENV
cat > "$DIR/publisher.env" <<ENV
BUCKET=$BUCKET
PREFIX=site
ENV
echo 'console.log("shop v2026.10");' > "$DIR/assets/app.js"
echo 'body { font-family: sans-serif; }' > "$DIR/assets/style.css"
echo '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"/>' > "$DIR/assets/logo.svg"
cat > "$DIR/publish.sh" <<'SH'
#!/usr/bin/env bash
# Publishes the static assets. From the wiki page "Publishing static assets to S3" (2019).
# usage: ./publish.sh [ASSET_DIR] [PREFIX]      (default: ./assets, site)
set -euo pipefail
cd "$(dirname "$0")"
. ./aws-env.sh
. ./publisher.env

SRC="${1:-assets}"
DEST="${2:-$PREFIX}"

aws s3 sync "$SRC" "s3://$BUCKET/$DEST" --acl public-read
echo "published $SRC -> s3://$BUCKET/$DEST"
SH
chmod +x "$DIR/publish.sh"

# Prove the symptom is real (and capture its text).
bash "$DIR/publish.sh" >"$STATE/logs/drill75-probe.log" 2>&1 && {
  echo "the probe publish SUCCEEDED, the drill would be a no-op" >&2; exit 1; }
grep -q AccessControlListNotSupported "$STATE/logs/drill75-probe.log" \
  || { echo "unexpected probe error: $(cat "$STATE/logs/drill75-probe.log")" >&2; exit 1; }
exit 0
