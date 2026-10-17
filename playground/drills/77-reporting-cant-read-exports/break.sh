#!/usr/bin/env bash
# Reporting's bucket access was granted per prefix -- reports/ only -- and the
# data team started writing monthly exports to a NEW prefix, exports/.
#
# Creates (tagged platform-lab-drill=77, prefix platform-lab-drill77):
#   role ...-reporting  trusted by the lab user, NO identity policy (DeletePolicy and
#                       PutRolePolicy are denied on this account): its access lives in the
#                       bucket policy below (Principal "*" + aws:PrincipalArn = the role).
#   bucket              platform-lab-drill77-<acct>-<rand>, reports/2026-09.csv and
#                       exports/2026-10.csv; bucket policy: s3:ListBucket on the BUCKET ARN
#                       only with s3:prefix = reports/..., s3:GetObject on .../reports/* only.
# and a workspace ~/platform-playground-aws/drill77 with fetch.sh: lab user -> reporting role
# -> list a prefix and download what is listed. `./fetch.sh reports/` works; `./fetch.sh`
# (exports/) fails on the LIST first, and after fixing the list it fails on the GET.
#
# Everything is recorded in $STATE/drill77.env BEFORE the first create; reset.sh acts only on it.
# AWS API calls: sts:GetCallerIdentity, iam:CreateRole, s3:CreateBucket, PutBucketTagging,
# PutPublicAccessBlock, PutObject, PutBucketPolicy, sts:AssumeRole (probe), ListObjectsV2.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
mkdir -p "$STATE/logs"
REC="$STATE/drill77.env"
DIR="$WORK/drill77"

[[ -f $REC ]] && bash "$HERE/reset.sh"

acct=$(aws_account)
ME_ARN=$(aws sts get-caller-identity --query Arn --output text)
ROLE=platform-lab-drill77-reporting
BUCKET="platform-lab-drill77-$acct-$(printf '%04x%04x' $RANDOM $RANDOM)"
ROLE_ARN="arn:aws:iam::$acct:role/$ROLE"
umask 077
cat > "$REC" <<R
ROLE=$ROLE
BUCKET=$BUCKET
ME_ARN=$ME_ARN
R

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
TAGS="Key=platform-lab-drill,Value=77"
cat > "$T/trust.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"AWS":"$ME_ARN"},"Action":"sts:AssumeRole"}]}
JSON
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$T/trust.json" \
  --description "platform-lab drill 77: the reporting job's identity" --tags $TAGS >/dev/null

aws s3api create-bucket --bucket "$BUCKET" --region us-east-1 >/dev/null
aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging 'TagSet=[{Key=platform-lab-drill,Value=77},{Key=owner,Value=data-platform}]'
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
printf 'month,orders,revenue\n2026-09,1204,48210.50\n' > "$T/r.csv"
printf 'month,orders,revenue\n2026-10,1377,55102.25\n' > "$T/e.csv"
aws s3api put-object --bucket "$BUCKET" --key reports/2026-09.csv --body "$T/r.csv" >/dev/null
aws s3api put-object --bucket "$BUCKET" --key exports/2026-10.csv --body "$T/e.csv" >/dev/null

# Principal "*" narrowed by aws:PrincipalArn = the role: the policy keeps working if the role is recreated.
cat > "$T/bucket-policy.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"ReportingListReports","Effect":"Allow","Principal":"*",
  "Action":"s3:ListBucket","Resource":"arn:aws:s3:::$BUCKET",
  "Condition":{"ArnEquals":{"aws:PrincipalArn":"$ROLE_ARN"},
               "StringLike":{"s3:prefix":["reports/*"]}}},
 {"Sid":"ReportingReadReports","Effect":"Allow","Principal":"*",
  "Action":"s3:GetObject","Resource":"arn:aws:s3:::$BUCKET/reports/*",
  "Condition":{"ArnEquals":{"aws:PrincipalArn":"$ROLE_ARN"}}}]}
JSON
for _ in $(seq 1 15); do
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$T/bucket-policy.json" 2>/dev/null && break
  sleep 4
done
aws s3api get-bucket-policy --bucket "$BUCKET" >/dev/null

# --- the workspace ------------------------------------------------------------
rm -rf "$DIR"; mkdir -p "$DIR"
cat > "$DIR/aws-env.sh" <<ENV
# Lab credentials into THIS shell (never into ~/.aws):   . ./aws-env.sh
# They stand in for "the reporting job's host identity"; the job itself runs as the role.
set -a; . "$AWS_CREDS_FILE"; set +a
unset AWS_PROFILE
export AWS_DEFAULT_REGION=us-east-1 AWS_REGION=us-east-1
ENV
cat > "$DIR/reporting.env" <<ENV
ROLE_ARN=$ROLE_ARN
BUCKET=$BUCKET
ENV
cat > "$DIR/fetch.sh" <<'SH'
#!/usr/bin/env bash
# Reporting job: assume the reporting role, list a prefix of the data bucket and
# download everything listed into ./out/.
# usage: ./fetch.sh [PREFIX]        (default: exports/ -- this month's new location)
set -euo pipefail
cd "$(dirname "$0")"
. ./aws-env.sh
. ./reporting.env
PREFIX="${1:-exports/}"

c=$(aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name reporting-fetch --duration-seconds 900 \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$c"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
echo "fetching as: $(aws sts get-caller-identity --query Arn --output text)"

mkdir -p out
keys=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX" --query 'Contents[].Key' --output text)
for k in $keys; do
  [[ $k == None ]] && continue
  aws s3api get-object --bucket "$BUCKET" --key "$k" "out/$(basename "$k")" >/dev/null
  echo "downloaded $k"
done
SH
chmod +x "$DIR/fetch.sh"
cp "$DIR/fetch.sh" "$STATE/drill77.fetch.orig"

# Wait until the role is assumable and the EXPORTS list is denied (fail the break if
# it never is, or fails some other way: then the drill would be a no-op).
for _ in $(seq 1 25); do
  if bash "$DIR/fetch.sh" >"$STATE/logs/drill77-probe.log" 2>&1; then
    echo "the probe fetch.sh unexpectedly worked" >&2; exit 1
  fi
  if grep -q 'AccessDenied' "$STATE/logs/drill77-probe.log" && grep -q 'ListObjectsV2' "$STATE/logs/drill77-probe.log"; then
    bash "$DIR/fetch.sh" reports/ >"$STATE/logs/drill77-probe2.log" 2>&1 \
      && grep -q 'downloaded reports/2026-09.csv' "$STATE/logs/drill77-probe2.log" && exit 0
  fi
  sleep 3
done
echo "the probe never failed on the exports list: $(cat "$STATE/logs/drill77-probe.log")" >&2
exit 1
