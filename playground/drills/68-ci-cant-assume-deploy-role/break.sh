#!/usr/bin/env bash
# The security review tightens a deploy role's trust policy -- and gets it
# subtly wrong, while the CI script still assumes the role the old way.
#
# Creates (all tagged platform-lab-drill=68, prefix platform-lab-drill68):
#   role ...-ci         the "CI system identity": trusted by the lab user (stands in for
#                       Jenkins/GitHub runners outside AWS). NO permissions of its own.
#   role ...-legacy-ci  a real role nobody can assume (trusts ec2.amazonaws.com): the
#                       WRONG principal the review typed into the deploy role's trust.
#   role ...-deploy     trust: Principal = legacy-ci (WRONG), Condition sts:ExternalId = the
#                       value in the security ticket. No IAM permissions: the bucket policy
#                       below grants it s3:ListBucket/GetObject (DeletePolicy and PutRolePolicy
#                       are denied on this account, so no policy is created that reset could
#                       not remove). iam:UpdateAssumeRolePolicy is DENIED too (probed 2026-10-17):
#                       the trust is fixed by deleting and recreating the role.
#   bucket              platform-lab-drill68-<acct>-<rand>, one object deploy/manifest.txt,
#                       bucket policy: Allow list/get to principals whose ARN is the deploy role only.
# and a workspace ~/platform-playground-aws/drill68 with deploy.sh: lab user -> CI role ->
# deploy role (WITHOUT --external-id) -> list the bucket. The second hop fails:
#   AccessDenied ... sts:AssumeRole on resource: .../platform-lab-drill68-deploy
# (the same text for a wrong principal and for a missing ExternalId: that is the trap.)
#
# Everything is recorded in $STATE/drill68.env BEFORE the first create; reset.sh acts only on it.
#
# AWS API calls: sts:GetCallerIdentity, iam:CreateRole (x3, tagged), s3:CreateBucket,
# PutBucketTagging, PutPublicAccessBlock, PutObject, PutBucketPolicy, sts:AssumeRole (probe).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
mkdir -p "$STATE/logs"
REC="$STATE/drill68.env"
DIR="$WORK/drill68"

# An earlier run of this drill in THIS state dir: clean it up first.
[[ -f $REC ]] && bash "$HERE/reset.sh"

acct=$(aws_account)
ME_ARN=$(aws sts get-caller-identity --query Arn --output text)
CI=platform-lab-drill68-ci; LEGACY=platform-lab-drill68-legacy-ci; DEPLOY=platform-lab-drill68-deploy
BUCKET="platform-lab-drill68-$acct-$(printf '%04x%04x' $RANDOM $RANDOM)"
EXTID="plt-ci-7f3a91"
umask 077
cat > "$REC" <<R
CI=$CI
LEGACY=$LEGACY
DEPLOY=$DEPLOY
BUCKET=$BUCKET
EXTID=$EXTID
ME_ARN=$ME_ARN
R

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
TAGS="Key=platform-lab-drill,Value=68"

cat > "$T/ci-trust.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"AWS":"$ME_ARN"},"Action":"sts:AssumeRole"}]}
JSON
cat > "$T/legacy-trust.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
aws iam create-role --role-name "$CI" --assume-role-policy-document "file://$T/ci-trust.json" \
  --description "platform-lab drill 68: the CI system's identity" --tags $TAGS >/dev/null
aws iam create-role --role-name "$LEGACY" --assume-role-policy-document "file://$T/legacy-trust.json" \
  --description "platform-lab drill 68: the old CI role (unusable)" --tags $TAGS >/dev/null

CI_ARN="arn:aws:iam::$acct:role/$CI"; LEGACY_ARN="arn:aws:iam::$acct:role/$LEGACY"
DEPLOY_ARN="arn:aws:iam::$acct:role/$DEPLOY"
# SEC-341 as merged: the principal is the OLD ci role (typo), the ExternalId is right.
cat > "$T/deploy-trust.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"AWS":"$LEGACY_ARN"},"Action":"sts:AssumeRole",
  "Condition":{"StringEquals":{"sts:ExternalId":"$EXTID"}}}]}
JSON
# A new principal can take a few seconds to be visible to IAM.
for _ in $(seq 1 10); do
  aws iam create-role --role-name "$DEPLOY" --assume-role-policy-document "file://$T/deploy-trust.json" \
    --description "platform-lab drill 68: deploy role" --tags $TAGS >/dev/null 2>&1 && break
  sleep 3
done
aws iam get-role --role-name "$DEPLOY" >/dev/null

aws s3api create-bucket --bucket "$BUCKET" --region us-east-1 >/dev/null
aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging 'TagSet=[{Key=platform-lab-drill,Value=68},{Key=owner,Value=ci-platform}]'
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
echo "release 2026.10.2 manifest" > "$T/manifest.txt"
aws s3api put-object --bucket "$BUCKET" --key deploy/manifest.txt --body "$T/manifest.txt" >/dev/null
# Principal "*" narrowed by aws:PrincipalArn = the deploy role's ARN (not the role itself, and not
# the account root, which would only delegate to identity policies the role does not have): the role's trust cannot be edited on this account (UpdateAssumeRolePolicy is
# denied), so the fix is to recreate the role, and a policy that names the role directly would
# keep pointing at the deleted role's unique id.
cat > "$T/bucket-policy.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"DeployRoleReads","Effect":"Allow","Principal":"*",
  "Action":["s3:ListBucket","s3:GetObject"],
  "Resource":["arn:aws:s3:::$BUCKET","arn:aws:s3:::$BUCKET/*"],
  "Condition":{"ArnEquals":{"aws:PrincipalArn":"$DEPLOY_ARN"}}}]}
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
# They stand in for "the CI system's own identity".
set -a; . "$AWS_CREDS_FILE"; set +a
unset AWS_PROFILE
export AWS_DEFAULT_REGION=us-east-1 AWS_REGION=us-east-1
ENV
cat > "$DIR/ci.env" <<ENV
CI_ROLE_ARN=$CI_ARN
DEPLOY_ROLE_ARN=$DEPLOY_ARN
BUCKET=$BUCKET
ENV
cat > "$DIR/deploy.sh" <<'SH'
#!/usr/bin/env bash
# CI deploy step. The CI system has no AWS permissions of its own: it assumes the
# CI role, and from there the narrowly-trusted deploy role, then deploys.
set -euo pipefail
cd "$(dirname "$0")"
. ./aws-env.sh
. ./ci.env

# assume ROLE_ARN SESSION_NAME [extra sts args]: switch THIS process to the role's credentials
assume() {
  local c
  c=$(aws sts assume-role --role-arn "$1" --role-session-name "$2" --duration-seconds 900 \
        "${@:3}" --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$c"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

assume "$CI_ROLE_ARN" ci-deploy
assume "$DEPLOY_ROLE_ARN" ci-deploy

echo "deploying as: $(aws sts get-caller-identity --query Arn --output text)"
aws s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].Key' --output text
SH
chmod +x "$DIR/deploy.sh"
cp "$DIR/deploy.sh" "$STATE/drill68.deploy.orig"

# IAM is eventually consistent: wait until the SECOND hop is denied (and fail the break
# if it never is, or fails some other way: then the drill would be a no-op).
for _ in $(seq 1 25); do
  if bash "$DIR/deploy.sh" >"$STATE/logs/drill68-probe.log" 2>&1; then
    echo "the probe deploy.sh unexpectedly worked" >&2; exit 1
  fi
  if grep -q 'AccessDenied' "$STATE/logs/drill68-probe.log" \
     && grep -q "resource: $DEPLOY_ARN" "$STATE/logs/drill68-probe.log"; then exit 0; fi
  sleep 3
done
echo "the probe never failed on the deploy-role hop: $(cat "$STATE/logs/drill68-probe.log")" >&2
exit 1
