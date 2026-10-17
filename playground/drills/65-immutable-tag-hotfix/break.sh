#!/usr/bin/env bash
# The payments team ships a hotfix by re-using the version tag; the platform
# team's baseline made the ECR repository immutable.
#
# Creates ONE ECR repository platform-lab-drill65/payments-api (tagged
# platform-lab-drill=65) with imageTagMutability IMMUTABLE and scanOnPush on,
# pushes a tiny busybox-based image as tag 1.4.0 (digest recorded), and writes
# a workspace ~/platform-playground-aws/drill65 with release.sh -- the
# teammate's script, which builds a DIFFERENT "hotfix" image and pushes it as
# 1.4.0 again. The push is refused. break.sh runs it once to prove it.
#
# Everything it creates is recorded in $STATE/drill65.env BEFORE it is created;
# reset.sh acts ONLY on that record. Docker credentials never touch
# ~/.docker: every docker call uses a throwaway DOCKER_CONFIG that is deleted.
#
# AWS API calls: sts:GetCallerIdentity, ecr:CreateRepository (IMMUTABLE,
# scanOnPush, tags), GetAuthorizationToken, InitiateLayerUpload/UploadLayerPart/
# CompleteLayerUpload/PutImage (docker push), DescribeImages, DescribeRepositories.
# docker: pull busybox (public ECR, anonymous), build, tag, push, run (none).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
mkdir -p "$STATE/logs"
REC="$STATE/drill65.env"
DIR="$WORK/drill65"
BASE=public.ecr.aws/docker/library/busybox:1.36.1

command -v docker >/dev/null && docker info >/dev/null 2>&1 || die "Docker is not running: this drill builds and pushes a tiny image."

# An earlier run of this drill in THIS state dir: clean it up first.
[[ -f $REC ]] && bash "$HERE/reset.sh"

acct=$(aws_account)
REGION=${AWS_REGION:-us-east-1}
REPO="platform-lab-drill65/payments-api"
REGISTRY="$acct.dkr.ecr.$REGION.amazonaws.com"
URI="$REGISTRY/$REPO"

# Record first, create second: reset finds whatever exists.
umask 077
{
  printf 'REPO=%s\n' "$REPO"
  printf 'REGISTRY=%s\n' "$REGISTRY"
  printf 'DIR=%s\n' "$DIR"
  printf 'LOCAL_PREFIX=%s:\n' "$URI"      # every local image reset may remove starts with this
} > "$REC"

aws ecr create-repository --repository-name "$REPO" \
  --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true \
  --tags Key=platform-lab-drill,Value=65 Key=owner,Value=platform-sec-baseline >/dev/null

# --- the workspace ------------------------------------------------------------
rm -rf "$DIR"; mkdir -p "$DIR/app"
cat > "$DIR/aws-env.sh" <<ENV
# Lab credentials into THIS shell (never into ~/.aws):   . ./aws-env.sh
set -a; . "$AWS_CREDS_FILE"; set +a
unset AWS_PROFILE
export AWS_DEFAULT_REGION=us-east-1 AWS_REGION=us-east-1
ENV
cat > "$DIR/release.env" <<ENV
# payments-api release settings
REGISTRY=$REGISTRY
REPO=$REPO
VERSION=1.4.0
ENV
cat > "$DIR/app/Dockerfile" <<DF
FROM $BASE
LABEL org.opencontainers.image.title=payments-api
COPY release-info.txt /release-info.txt
CMD ["cat", "/release-info.txt"]
DF
cat > "$DIR/app/release-info.txt" <<'TXT'
payments-api 1.4.0 + HOTFIX PAY-2291: retry settlement on timeout, cap at 3 attempts
TXT
cat > "$DIR/release.sh" <<'SH'
#!/usr/bin/env bash
# payments-api release: build the image from ./app and push it to ECR.
# usage: ./release.sh [--dry-run]     (--dry-run: print the tag, build and push nothing)
# Our convention (Dana): a hotfix keeps the version it fixes, so the tag is just $VERSION.
set -euo pipefail
cd "$(dirname "$0")"
. ./release.env

TAG="$VERSION"
IMAGE="$REGISTRY/$REPO:$TAG"

if [[ ${1:-} == --dry-run ]]; then
  echo "would build and push $IMAGE"
  exit 0
fi

. ./aws-env.sh
# Throwaway docker config: the ECR token must not end up in ~/.docker.
export DOCKER_CONFIG="$(mktemp -d)"
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
[[ -d $HOME/.docker/cli-plugins ]] && ln -s "$HOME/.docker/cli-plugins" "$DOCKER_CONFIG/cli-plugins"
[[ -S $HOME/.docker/run/docker.sock ]] && export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.docker/run/docker.sock}"

aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null 2>&1
docker build -q -t "$IMAGE" ./app >/dev/null
docker push -q "$IMAGE" >/dev/null
echo "released $IMAGE"
SH
chmod +x "$DIR/release.sh"

# --- the original 1.4.0, built from a SEPARATE context (not the hotfix source) ----
ORIG=$(mktemp -d)
export DOCKER_CONFIG="$(mktemp -d)"
trap 'rm -rf "$ORIG" "$DOCKER_CONFIG"' EXIT
[[ -d $HOME/.docker/cli-plugins ]] && ln -s "$HOME/.docker/cli-plugins" "$DOCKER_CONFIG/cli-plugins"
[[ -S $HOME/.docker/run/docker.sock ]] && export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.docker/run/docker.sock}"
cp "$DIR/app/Dockerfile" "$ORIG/Dockerfile"
echo "payments-api 1.4.0 (released $(date -u +%F), what prod runs today)" > "$ORIG/release-info.txt"
docker pull -q "$BASE" >/dev/null
docker build -q -t "$URI:1.4.0" "$ORIG" >/dev/null
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null 2>&1
docker push -q "$URI:1.4.0" >/dev/null

ORIG_DIGEST=$(aws ecr describe-images --repository-name "$REPO" --image-ids imageTag=1.4.0 \
  --query 'imageDetails[0].imageDigest' --output text)
ORIG_PUSHED=$(aws ecr describe-images --repository-name "$REPO" --image-ids imageTag=1.4.0 \
  --query 'imageDetails[0].imagePushedAt' --output text)
{ printf 'ORIG_DIGEST=%s\n' "$ORIG_DIGEST"; printf 'ORIG_PUSHED="%s"\n' "$ORIG_PUSHED"; } >> "$REC"

# --- the symptom: run the teammate's release as is; it must be refused ---------
out=$(cd "$DIR" && ./release.sh 2>&1) && {
  echo "release.sh succeeded: the repository is not enforcing immutability: $out" >&2; exit 1; }
printf '%s\n' "$out" > "$STATE/logs/drill65-probe.log"
grep -Eqi 'already exists|immutable' <<<"$out" || { echo "unexpected failure: $out" >&2; exit 1; }
exit 0
