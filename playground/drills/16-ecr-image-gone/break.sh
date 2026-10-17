#!/usr/bin/env bash
# The cloud team adds an ECR lifecycle policy "to save storage"; its first run
# deletes the image prod is running. Running pods keep working; a new one cannot pull.
#
# HONEST PART: ECR evaluates lifecycle policies asynchronously, up to ~24 h after
# they are saved, and an age rule expires nothing pushed less than a day ago. So
# this script installs the policy AND performs the deletion itself, the way the
# policy's first run would a day later (batch-delete-image). It also sets
# imagePullPolicy: Always on the Deployment, because the nodes still hold the
# image in their local cache and a new pod would start from it; Always makes every
# new pod behave like one on a fresh node (scale-up, node replacement).
#
# API calls:
#   ecr   DescribeImages, ListImages, GetLifecyclePolicy        (read)
#         BatchDeleteImage (a no-op probe on a tag that does not exist, then the real one)
#         PutLifecyclePolicy                                     (up-aws.sh already uses it)
#   kube  patch deployment demo-ci/demo-api, delete one pod
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
mkdir -p "$STATE"
SNAP="$STATE/drill16-policy.baseline.json"
NS=demo-ci

img=$(K -n $NS get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ $img == "$(ecr_registry)/$ECR_REPO:"* ]] || die "demo-api runs $img, not an image from $ECR_REPO. Run playground/setup/up-aws.sh (or play reset) first."
tag=${img##*:}
K -n $NS rollout status deploy/demo-api --timeout=20s >/dev/null || die "demo-api is not healthy before the break. Run play reset first."
aws ecr describe-images --repository-name "$ECR_REPO" --image-ids imageTag="$tag" >/dev/null \
  || die "the running tag $tag is not in ECR already. Run play reset first."

# Is deleting images allowed here at all? A tag that does not exist: a refused
# call fails with AccessDenied (exit != 0); an allowed one reports ImageNotFound.
aws ecr batch-delete-image --repository-name "$ECR_REPO" --image-ids imageTag=drill16-permission-probe >/dev/null \
  || die "ecr:BatchDeleteImage is refused on this account: this drill cannot simulate the policy's run."

# Keep the current policy so reset can put it back exactly.
[[ -f $SNAP ]] || aws ecr get-lifecycle-policy --repository-name "$ECR_REPO" \
  --query lifecyclePolicyText --output text > "$SNAP" 2>/dev/null || rm -f "$SNAP"

# 1. Every new pod must pull. Done first, while the image still exists, so the
#    rollout this causes completes normally.
K -n $NS patch deploy demo-api -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"demo-api","imagePullPolicy":"Always"}]}}}}' >/dev/null
K -n $NS rollout status deploy/demo-api --timeout=240s >/dev/null || die "demo-api did not roll out with imagePullPolicy Always"

# 2. The teammate's policy. Anything older than a day, whatever it is, whatever runs it.
aws ecr put-lifecycle-policy --repository-name "$ECR_REPO" --lifecycle-policy-text '{
  "rules": [{
    "rulePriority": 1,
    "description": "COST-212: save storage, nothing older than a day",
    "selection": {"tagStatus": "any", "countType": "sinceImagePushed", "countUnit": "days", "countNumber": 1},
    "action": {"type": "expire"}
  }]
}' >/dev/null

# 3. "Simulating the policy's run": delete what that rule would delete a day from
#    now. Everything in the repo is, by then, older than a day.
ids=$(aws ecr list-images --repository-name "$ECR_REPO" --output json | jq -c '[.imageIds[:100][]]')
aws ecr batch-delete-image --repository-name "$ECR_REPO" --image-ids "$ids" >/dev/null

# 4. A "reschedule": one pod goes away, its replacement cannot pull.
victim=$(K -n $NS get pods -l app=demo-api -o name | head -1)
K -n $NS delete "$victim" --wait=false >/dev/null
for _ in $(seq 1 40); do
  if K -n $NS get pods -l app=demo-api -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' \
       | grep -Eq 'ErrImagePull|ImagePullBackOff'; then
    exit 0
  fi
  sleep 3
done
die "the replacement pod never reached ImagePullBackOff (is the image really gone?)"
