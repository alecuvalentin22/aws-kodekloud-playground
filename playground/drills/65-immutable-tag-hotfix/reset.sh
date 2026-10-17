#!/usr/bin/env bash
# Deletes what break.sh recorded in $STATE/drill65.env -- the ECR repository
# (--force, after confirming the name prefix and the drill tag), the workspace,
# and the local docker images whose reference starts with the repository URI --
# and nothing else (the public busybox base image is left alone). No record, no
# action: other lanes' `play reset` runs this where drill 65 never started.
# Skipped silently without AWS credentials, so a local `play reset` never fails here.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"
REC="$STATE/drill65.env"
[[ -f $REC ]] || exit 0
[[ -r $AWS_CREDS_FILE ]] || exit 0
aws_env
REPO=""; DIR=""; LOCAL_PREFIX=""
# shellcheck disable=SC1090
source "$REC"
if [[ $REPO == platform-lab-drill65/* ]]; then
  rc=0; arn=$(aws ecr describe-repositories --repository-names "$REPO" --query 'repositories[0].repositoryArn' --output text 2>&1) || rc=$?
  if (( rc != 0 )) && grep -q RepositoryNotFoundException <<<"$arn"; then
    :   # already gone
  elif (( rc != 0 )); then
    c_warn "drill 65: cannot read $REPO (${arn:0:120}); record kept, run reset again"; exit 0
  else
    t=$(aws ecr list-tags-for-resource --resource-arn "$arn" --query "tags[?Key=='platform-lab-drill'].Value" --output text 2>/dev/null || echo 65)
    if [[ $t != 65 ]]; then
      c_warn "drill 65: $REPO does not carry platform-lab-drill=65; not touching it"
    else
      aws ecr delete-repository --repository-name "$REPO" --force >/dev/null 2>&1 \
        || { c_warn "drill 65: could not delete $REPO; record kept, run reset again"; exit 0; }
    fi
  fi
fi
[[ -n $DIR && $DIR == */drill65 ]] && rm -rf "$DIR"
if [[ $LOCAL_PREFIX == */platform-lab-drill65/payments-api:* ]] && command -v docker >/dev/null 2>&1; then
  export DOCKER_CONFIG="$(mktemp -d)"
  [[ -d $HOME/.docker/cli-plugins ]] && ln -s "$HOME/.docker/cli-plugins" "$DOCKER_CONFIG/cli-plugins"
  [[ -S $HOME/.docker/run/docker.sock ]] && export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.docker/run/docker.sock}"
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | awk -v p="$LOCAL_PREFIX" 'index($0,p)==1' \
    | while read -r ref; do docker rmi "$ref" >/dev/null 2>&1 || true; done
  rm -rf "$DOCKER_CONFIG"
fi
rm -f "$REC" "$STATE/drill65.mutable-seen"
exit 0
