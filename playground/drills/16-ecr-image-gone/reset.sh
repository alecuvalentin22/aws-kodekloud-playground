#!/usr/bin/env bash
# Puts back what break.sh changed: the repository's lifecycle policy (the snapshot
# break.sh took, else the lab default "keep the last 10") and imagePullPolicy on
# demo-api. It cannot put the DELETED IMAGE back -- the baseline rebuild that
# `up-aws.sh --reset` runs after the reset scripts pushes and deploys a fresh one.
# Skipped silently when the AWS tier is not up, so a local `play reset` never fails here.
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"
aws_tier_up || exit 0
aws_env
SNAP="$STATE/drill16-policy.baseline.json"
DEFAULT='{"rules":[{"rulePriority":1,"description":"keep last 10","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},"action":{"type":"expire"}}]}'
if [[ -s $SNAP ]] && jq -e . "$SNAP" >/dev/null 2>&1; then
  aws ecr put-lifecycle-policy --repository-name "$ECR_REPO" --lifecycle-policy-text "$(cat "$SNAP")" >/dev/null
else
  aws ecr put-lifecycle-policy --repository-name "$ECR_REPO" --lifecycle-policy-text "$DEFAULT" >/dev/null
fi
rm -f "$SNAP"
K -n default delete pod ecr-pull-probe --ignore-not-found --wait=false >/dev/null 2>&1
if [[ $(K -n demo-ci get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}' 2>/dev/null) == Always ]]; then
  K -n demo-ci patch deploy demo-api --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >/dev/null
fi
exit 0
