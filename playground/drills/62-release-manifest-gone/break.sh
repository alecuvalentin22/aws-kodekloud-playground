#!/usr/bin/env bash
# A "tidy the release bucket" job goes wrong, on a REAL versioned S3 bucket:
#   releases/manifest.json  v1 (release 2026.10.1) -> v2 (2026.10.2, the good one,
#                           written by the release pipeline) -> v3 (the job's truncated rewrite)
#   releases/notes.md       v1, then DELETED (a delete marker on top; the data is still there)
# Everything is written with put-object and metadata (pipeline/build-id) so a server-side
# restore of a version can be told from a re-upload of the same bytes from a laptop.
# Records the bucket, version ids and sha256s in "$STATE/drill62.env" (reset.sh and
# check.sh read only that).
# AWS API calls: s3:CreateBucket, PutPublicAccessBlock, PutBucketTagging, PutBucketVersioning,
#   PutObject, DeleteObject (+ ListObjectVersions / DeleteBucket via reset.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
for t in aws jq openssl; do command -v "$t" >/dev/null || die "$t not on PATH"; done
REC="$STATE/drill62.env"
mkdir -p "$STATE/logs"
bash "$HERE/reset.sh" || true                 # a bucket left by an earlier run of THIS lane
[[ -f $REC ]] && die "an earlier drill-62 bucket could not be removed ($REC); run reset.sh"

sha() { if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

acct=$(aws_account)
BUCKET="platform-lab-drill62-$acct-$(openssl rand -hex 3)"
echo "BUCKET=$BUCKET" > "$REC"
aws s3api create-bucket --bucket "$BUCKET" >/dev/null
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging 'TagSet=[{Key=platform-lab-drill,Value=62}]'
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled

put() {   # put <key> <file> <metadata>   -> prints the new VersionId
  aws s3api put-object --bucket "$BUCKET" --key "$1" --body "$2" --metadata "$3" \
    --content-type "${4:-application/json}" --query VersionId --output text
}

cat > "$T/m1.json" <<'J'
{
  "release": "2026.10.1",
  "approved_by": "sam",
  "services": [
    {"name": "payments-api",  "image": "platform-lab/demo-api:main-9b1e07c-38",      "replicas": 2},
    {"name": "ledger-worker", "image": "platform-lab/ledger-worker:main-41d0aa2-12", "replicas": 1}
  ]
}
J
cat > "$T/m2.json" <<'J'
{
  "release": "2026.10.2",
  "approved_by": "priya",
  "change_window": "2026-10-16T18:00:00Z",
  "services": [
    {"name": "payments-api",  "image": "platform-lab/demo-api:main-c4a77e1-41",      "replicas": 3},
    {"name": "ledger-worker", "image": "platform-lab/ledger-worker:main-77be3d9-15", "replicas": 2}
  ]
}
J
# What a cleanup job that rewrites files in place leaves behind when it is killed half way.
printf '{\n  "release": "2026.10.3",\n  "services": [\n    {"name": "payments-api", "image": "platform-lab/demo-api:' > "$T/m3.json"
cat > "$T/notes.md" <<'N'
# Release 2026.10.2

- payments-api: ledger retries are now idempotent (PAY-1184)
- ledger-worker: batch size 200 -> 500
- Rollback: redeploy the previous manifest; no schema change in this release.
N

M1_VID=$(put releases/manifest.json "$T/m1.json" "pipeline=release-pipeline,build-id=2398"); sleep 1
M2_VID=$(put releases/manifest.json "$T/m2.json" "pipeline=release-pipeline,build-id=2417"); sleep 1
N1_VID=$(put releases/notes.md "$T/notes.md" "pipeline=release-pipeline,build-id=2417" text/markdown); sleep 1
# --- the "cleanup script gone wrong" ---------------------------------------
M3_VID=$(put releases/manifest.json "$T/m3.json" "pipeline=bucket-tidy-job"); sleep 1
DM_VID=$(aws s3api delete-object --bucket "$BUCKET" --key releases/notes.md --query VersionId --output text)

cat >> "$REC" <<R
M1_VID=$M1_VID
M1_SHA=$(sha "$T/m1.json")
M2_VID=$M2_VID
M2_SHA=$(sha "$T/m2.json")
M2_BUILD=2417
M3_VID=$M3_VID
M3_SHA=$(sha "$T/m3.json")
N1_VID=$N1_VID
N1_SHA=$(sha "$T/notes.md")
N1_BUILD=2417
DM_VID=$DM_VID
VERSIONS=4
R
echo "drill 62: bucket $BUCKET, manifest v1/v2/v3 + notes v1 + 1 delete marker"
