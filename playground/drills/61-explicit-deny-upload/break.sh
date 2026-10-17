#!/usr/bin/env bash
# Security's bucket guardrails meet a "simplified" upload script.
#
# Creates ONE small S3 bucket (platform-lab-drill61-<account>-<rand>, tagged
# platform-lab-drill=61, block public access) with a bucket policy of two Deny
# statements -- "no PutObject without server-side encryption" and "no request
# over plain HTTP" -- and a workspace with upload.sh that a teammate
# "simplified": no encryption header, and an http:// endpoint. Both denials
# fire; the error text is the same for either.
#
# Everything it creates is recorded in $STATE/drill61.env; reset.sh acts ONLY on
# that record.
#
# AWS API calls: sts:GetCallerIdentity, s3:CreateBucket, PutBucketPublicAccessBlock,
# PutBucketTagging, PutBucketPolicy, GetBucketPolicy, PutObject (one probe, expected
# to be denied).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
mkdir -p "$STATE/logs"
REC="$STATE/drill61.env"
DIR="$WORK/drill61"

# An earlier run of this drill in THIS state dir: clean it up first.
[[ -f $REC ]] && bash "$HERE/reset.sh"

acct=$(aws_account)
BUCKET="platform-lab-drill61-$acct-$(printf '%04x%04x' $RANDOM $RANDOM)"
aws s3api create-bucket --bucket "$BUCKET" --region us-east-1 >/dev/null
# From here on the bucket exists: record it at once so reset can find it.
umask 077
printf 'BUCKET=%s\n' "$BUCKET" > "$REC"

aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging 'TagSet=[{Key=platform-lab-drill,Value=61},{Key=owner,Value=security-sec-318}]'
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

POLICY="$STATE/drill61.policy.json"
cat > "$POLICY" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyUnencryptedUploads",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::$BUCKET/*",
      "Condition": {"StringNotEquals": {"s3:x-amz-server-side-encryption": ["AES256", "aws:kms"]}}
    },
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::$BUCKET", "arn:aws:s3:::$BUCKET/*"],
      "Condition": {"Bool": {"aws:SecureTransport": "false"}}
    }
  ]
}
JSON
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$POLICY"
printf 'POLICY=%s\n' "$POLICY" >> "$REC"

# --- the workspace ------------------------------------------------------------
rm -rf "$DIR"; mkdir -p "$DIR"
cat > "$DIR/aws-env.sh" <<ENV
# Lab credentials into THIS shell (never into ~/.aws):   . ./aws-env.sh
set -a; . "$AWS_CREDS_FILE"; set +a
unset AWS_PROFILE
export AWS_DEFAULT_REGION=us-east-1 AWS_REGION=us-east-1
ENV
cat > "$DIR/uploader.env" <<ENV
BUCKET=$BUCKET
PREFIX=releases
ENV
cat > "$DIR/release-notes.txt" <<'TXT'
Release 2026.10.2
- payments: retry settlement on timeout
- tracker: migration marker
TXT
cat > "$DIR/upload.sh" <<'SH'
#!/usr/bin/env bash
# Release uploader: puts the release notes where the release job reads them.
# usage: ./upload.sh [FILE] [KEY]      (default: release-notes.txt, releases/<file name>)
# Simplified by Mihai: dropped the flags nobody remembered why they were there.
set -euo pipefail
cd "$(dirname "$0")"
. ./aws-env.sh
. ./uploader.env

FILE="${1:-release-notes.txt}"
KEY="${2:-$PREFIX/$(basename "$FILE")}"
ENDPOINT=http://s3.amazonaws.com        # plain HTTP: skips the TLS handshake, a bit faster

aws s3api put-object --endpoint-url "$ENDPOINT" \
  --bucket "$BUCKET" --key "$KEY" --body "$FILE" >/dev/null
echo "uploaded $FILE -> s3://$BUCKET/$KEY"
SH
chmod +x "$DIR/upload.sh"
cp "$DIR/upload.sh" "$STATE/drill61.upload.orig"

# The policy is eventually consistent for a moment; wait until the upload is
# denied (and fail the break if it never is: then the drill would be a no-op).
for _ in $(seq 1 20); do
  if ! bash "$DIR/upload.sh" >"$STATE/logs/drill61-probe.log" 2>&1; then
    grep -q AccessDenied "$STATE/logs/drill61-probe.log" && exit 0
  fi
  sleep 3
done
echo "the probe upload was never denied: $(cat "$STATE/logs/drill61-probe.log")" >&2
exit 1
