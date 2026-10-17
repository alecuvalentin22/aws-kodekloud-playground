#!/usr/bin/env bash
# A bucket goes public. A "tidy-up script" -- run with a distinctive userAgent --
# makes a handful of routine calls on it, then the two culprit ones: it switches
# S3 Block Public Access off for the bucket (PutBucketPublicAccessBlock, all four false)
# and attaches a bucket policy granting s3:GetObject to Principal "*"
# (PutBucketPolicy). The candidate has to contain it and reconstruct who/what/when
# from CloudTrail management events.
#
# HONEST PART: the identity in CloudTrail is the lab's IAM user, the same one the
# candidate uses (there is one set of keys). The way to tell the "teammate" from
# the candidate's own calls is the userAgent: the script runs with
# AWS_EXECUTION_ENV=platform-lab-tidy-script, which the CLI appends to the
# userAgent as exec-env/platform-lab-tidy-script. In real life you would also
# tell them apart by ARN and source IP.
#
# Records bucket, marker and the break time window in $STATE/drill67.env BEFORE
# anything is created. NOT the event IDs: the candidate must find them; check.sh
# looks them up again in CloudTrail.
#
# AWS API calls: sts GetCallerIdentity; s3 CreateBucket, PutBucketTagging,
# PutBucketPublicAccessBlock (x2), PutBucketPolicy, PutObject, GetBucketLocation,
# GetBucketTagging, GetBucketAcl, GetBucketPolicy, GetPublicAccessBlock,
# PutBucketLifecycleConfiguration, ListBuckets; cloudtrail LookupEvents (polling
# until the culprit event is visible, up to ~10 min).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
source "$HERE/trail.sh"
mkdir -p "$STATE/logs"
REC="$STATE/drill67.env"
DIR="$WORK/drill67"
MARKER=platform-lab-tidy-script

# An earlier run of this drill in THIS state dir: clean it up first.
[[ -f $REC ]] && bash "$HERE/reset.sh"

acct=$(aws_account)
BUCKET="platform-lab-drill67-$acct-$(printf '%04x%04x' $RANDOM $RANDOM)"
T0=$(date +%s)
# Recorded before anything exists, so reset can always find (and never miss) it.
umask 077
printf 'BUCKET=%s\nMARKER=%s\nACCT=%s\nT0=%s\n' "$BUCKET" "$MARKER" "$acct" "$T0" > "$REC"

aws s3api create-bucket --bucket "$BUCKET" --region us-east-1 >/dev/null
aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging 'TagSet=[{Key=platform-lab-drill,Value=67},{Key=owner,Value=analytics}]'
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
printf 'quarter,orders,refunds\n2026Q3,1204,31\n' > "$STATE/drill67.sample.csv"
aws s3api put-object --bucket "$BUCKET" --key exports/q3-summary.csv \
  --body "$STATE/drill67.sample.csv" --server-side-encryption AES256 >/dev/null
rm -f "$STATE/drill67.sample.csv"
sleep 5

# --- the teammate's tidy-up script ------------------------------------------------
POLICY="$STATE/drill67.public-policy.json"
cat > "$POLICY" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowExportDownloads",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::$BUCKET/exports/*"
  }]
}
JSON
LIFECYCLE='{"Rules":[{"ID":"expire-tmp","Status":"Enabled","Filter":{"Prefix":"tmp/"},"Expiration":{"Days":30}}]}'
(
  export AWS_EXECUTION_ENV="$MARKER"
  # routine "inventory" calls: noise in the trail
  aws s3api list-buckets >/dev/null || true
  aws s3api get-bucket-location --bucket "$BUCKET" >/dev/null || true
  aws s3api get-bucket-tagging --bucket "$BUCKET" >/dev/null || true
  aws s3api get-bucket-acl --bucket "$BUCKET" >/dev/null || true
  aws s3api get-public-access-block --bucket "$BUCKET" >/dev/null || true
  aws s3api get-bucket-policy --bucket "$BUCKET" >/dev/null 2>&1 || true   # NoSuchBucketPolicy
  aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration "$LIFECYCLE" >/dev/null || true
  # the culprits: guardrail off, then the world-readable policy
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$POLICY"
)
rm -f "$POLICY"

# Really public? Anonymous GET must work (the scanner's finding is real), after a short settle.
ok=no
for _ in $(seq 1 15); do
  if [[ $(curl -s -o /dev/null -w '%{http_code}' "https://$BUCKET.s3.amazonaws.com/exports/q3-summary.csv") == 200 ]]; then ok=yes; break; fi
  sleep 3
done
[[ $ok == yes ]] || { echo "the bucket never became anonymously readable" >&2; exit 1; }
echo "anonymous GET works: the bucket is public"

# --- workspace ---------------------------------------------------------------------
rm -rf "$DIR"; mkdir -p "$DIR" "$WORK/answers"
cat > "$DIR/aws-env.sh" <<ENV
# Lab credentials into THIS shell (never into ~/.aws):   . ./aws-env.sh
set -a; . "$AWS_CREDS_FILE"; set +a
unset AWS_PROFILE
export AWS_DEFAULT_REGION=us-east-1 AWS_REGION=us-east-1
ENV
cat > "$DIR/alert.txt" <<TXT
EXTERNAL EXPOSURE SCANNER -- finding SEC-5521
  resource : s3://$BUCKET
  finding  : anonymous (unauthenticated) GET succeeded
  object   : exports/q3-summary.csv
  seen at  : $(date -u +%FT%TZ) (scan time; not the time of the change)
TXT
cat > "$WORK/answers/67.template.md" <<TXT
# Incident note SEC-5521 (copy to 67.md and fill in)
API calls that opened the bucket:
EventId:
Identity (ARN):
Time (UTC):
userAgent marker:
Prevention (one line):
TXT

# --- wait until CloudTrail shows the culprit event, so the drill is solvable --------
# Management events usually appear after 1-3 minutes; the documented worst case is ~15.
# (Live: PutBucketPolicy was visible after ~70s, the PutBucketPublicAccessBlock sent
# in the same second took several minutes longer: events arrive one by one.)
for i in $(seq 1 30); do
  n=$(trail_culprits "$BUCKET" $((T0 - 60)) "$MARKER" 2>/dev/null | jq -s '[.[] | select(.name == "PutBucketPolicy")] | length' 2>/dev/null || echo 0)
  if [[ ${n:-0} -ge 1 ]]; then echo "PutBucketPolicy visible in CloudTrail after $(( $(date +%s) - T0 ))s since the break started"; exit 0; fi
  sleep 20
done
echo "WARNING: CloudTrail still did not show the PutBucketPolicy event after 10 min (events can take up to 15 min); the drill is on, the candidate must wait too" >&2
exit 0
