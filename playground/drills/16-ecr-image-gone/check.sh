#!/usr/bin/env bash
# Fixed means three things, none of them "the pipeline is green":
#   1. the tag prod runs exists in ECR again,
#   2. a NEW pod really pulls it (a probe pod with imagePullPolicy Always -- a
#      restart of a running pod could start from the node's image cache),
#   3. the lifecycle policy no longer expires the deployed tag, nor a future main-* tag,
#      and a lifecycle policy still exists (the teammate's storage worry is real).
# API calls: ecr DescribeImages, GetLifecyclePolicy (read); kube: apply/wait/delete one pod in `default`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
NS=demo-ci
fail=0

img=$(K -n $NS get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}')
if [[ $img != "$(ecr_registry)/$ECR_REPO:"* ]]; then c_bad "demo-api runs $img, which is not an image from $ECR_REPO"; exit 1; fi
tag=${img##*:}

# 1. the image is in ECR
if aws ecr describe-images --repository-name "$ECR_REPO" --image-ids imageTag="$tag" >/dev/null 2>&1; then
  c_ok "$tag is in ECR"
else
  c_bad "the tag demo-api runs ($tag) is not in $ECR_REPO"; exit 1
fi

# 2. a new pod pulls it
pod=ecr-pull-probe
cleanup() { K -n default delete pod $pod --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT
K -n default delete pod $pod --ignore-not-found --wait=true >/dev/null 2>&1
K -n default apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $pod, labels: {app: ecr-pull-probe}}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
    - name: demo-api
      image: $img
      imagePullPolicy: Always
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {memory: 256Mi}
YAML
if K -n default wait --for=condition=Ready pod/$pod --timeout=120s >/dev/null 2>&1; then
  c_ok "a brand-new pod pulled and started $tag"
else
  why=$(K -n default get pod $pod -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
  c_bad "a new pod cannot start from $img (${why:-not Ready after 120s})"; fail=1
fi
if K -n $NS rollout status deploy/demo-api --timeout=5s >/dev/null 2>&1; then
  c_ok "demo-api is fully rolled out"
else
  c_bad "demo-api is not fully rolled out: a pod is still stuck"; fail=1
fi
(( fail )) && exit 1

# 3. the policy
raw=$(aws ecr get-lifecycle-policy --repository-name "$ECR_REPO" --query lifecyclePolicyText --output text 2>&1); rc=$?
if (( rc != 0 )); then
  if grep -q 'LifecyclePolicyNotFound' <<<"$raw"; then
    c_warn "the repository has no lifecycle policy any more: nothing can expire the image, and nothing limits storage either"
    echo "PENALTY 30 You deleted the lifecycle policy instead of fixing it. The storage cost the cloud team raised is real: keep a policy, make it safe."
    exit 0
  fi
  c_bad "cannot read the lifecycle policy: ${raw:0:150}"; exit 1
fi
imgs=$(aws ecr describe-images --repository-name "$ECR_REPO" --output json \
        | jq -c '[.imageDetails[] | {tags: (.imageTags // []), pushed: .imagePushedAt}]')
eval1() {   # eval1 <images json> <tag>
  jq -c -n --argjson p "$raw" --argjson i "$1" --arg t "$2" '{policy: $p, images: $i, target: $t}' \
    | jq -c -f "$HERE/lifecycle.jq"
}
now_v=$(eval1 "$imgs" "$tag")
# A tag that does not exist yet and will be the newest: the next successful main build.
future="main-ffffffff-9999"
fut_v=$(eval1 "$(jq -c '. + [{tags: ["main-ffffffff-9999"], pushed: "9999-12-31T00:00:00Z"}]' <<<"$imgs")" "$future")
pfail=0
for who in now fut; do
  v=$([[ $who == now ]] && echo "$now_v" || echo "$fut_v")
  label=$([[ $who == now ]] && echo "the tag prod runs ($tag)" || echo "the next main-* build's tag")
  fate=$(jq -r .fate <<<"$v"); why=$(jq -r .why <<<"$v"); keep=$(jq -r '.keep // 0' <<<"$v")
  case $fate in
    expires) c_bad "policy would expire $label: $why"; pfail=1 ;;
    kept)
      if (( keep < 3 )); then
        c_bad "policy keeps only $keep image(s) for $label: one failed deploy's push (or a rollback) evicts what runs. Keep at least 3"; pfail=1
      else c_ok "policy keeps $label: $why"; fi ;;
    *) c_ok "no rule touches $label" ;;
  esac
done
(( pfail )) && exit 1
c_ok "the lifecycle policy still limits storage and no longer expires what is deployed"
