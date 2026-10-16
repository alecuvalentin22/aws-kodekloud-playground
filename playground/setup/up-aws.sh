#!/usr/bin/env bash
# The AWS tier of the playground, on the EXISTING EKS lab (make eks first).
#
#   playground/setup/up-aws.sh            install / repair (idempotent)
#   playground/setup/up-aws.sh --reset    back to baseline after an AWS drill
#
# Installs Gitea in the cluster, seeds platform/platform-lib + payments/demo-api
# into it, and (re)installs the lab's Jenkins release with
# setup/jenkins-values-aws.yaml layered on ci/jenkins/values.yaml -- so git
# comes from Gitea, images go to ECR, deploys go to EKS.
#
# NOTE: this takes over the lab's `jenkins` release (one NodePort 30094, one
# Jenkins). `make jenkins` puts back the GitHub-backed configuration.
#
# Credentials: ~/.config/platform-lab/aws-lab-creds.env (mode 600), never
# ~/.aws/credentials. State: ~/.local/state/platform-lab-playground/aws.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/../lib/aws.sh"

aws_env
mkdir -p "$STATE/scratch" "$STATE/logs" "$WORK"
chmod 700 "$STATE"

# --- reset -------------------------------------------------------------------
# `play reset` restores the LOCAL tier (its K is the kind cluster). This is
# the same procedure against the EKS Gitea and Jenkins.
if [[ ${1:-} == --reset ]]; then
  load_creds
  c_hdr "Resetting the AWS tier to baseline"
  for d in "$PG_ROOT"/drills/1[1-9]-*/; do
    [[ -f "$d/reset.sh" ]] && bash "$d/reset.sh" >>"$STATE/logs/reset.log" 2>&1
  done
  for repo in platform/platform-lib payments/demo-api; do
    dir="$STATE/scratch/reset"
    rm -rf "$dir"; git clone -q "$(repo_url "$repo")" "$dir"
    if [[ "$(git -C "$dir" rev-parse HEAD)" != "$(git -C "$dir" rev-parse 'baseline^{commit}')" ]]; then
      git -C "$dir" checkout -q baseline -- .
      git -C "$dir" diff --name-only --diff-filter=A baseline HEAD | while read -r f; do
        git -C "$dir" rm -q -- "$f"; done
      git -C "$dir" add -A
      git -C "$dir" -c user.name="playground reset" -c user.email=reset@playground.local \
        commit -q -m "reset to baseline" && git -C "$dir" push -q origin HEAD:main
      c_ok "$repo back to baseline content (as a new commit)"
    fi
    rm -rf "$dir"
  done
  rm -f "$HOME/.local/state/platform-lab-playground/current.env"
  b=$(build_main_and_wait 900) || die "baseline build did not finish"
  [[ $(jq -r .result <<<"$b") == SUCCESS ]] || die "baseline build: $b"
  c_ok "baseline main build green: $b. git pull in $WORK."
  exit 0
fi

c_hdr "0/6 preflight"
for t in kubectl helm git jq curl aws; do command -v $t >/dev/null || die "$t not on PATH"; done
ACCT=$(aws_account) || die "AWS credentials rejected"
[[ -f "$EKS_KUBECONFIG" ]] || die "No $EKS_KUBECONFIG: build the lab first (make eks)"
K get nodes >/dev/null || die "EKS cluster unreachable"
maxpods=$(K get nodes -o jsonpath='{.items[0].status.allocatable.pods}')
c_ok "account $ACCT, cluster $EKS_CLUSTER, $(K get nodes --no-headers | wc -l | tr -d ' ') nodes, max-pods $maxpods"
[[ $maxpods == 17 ]] && c_warn "max-pods 17: the ENI ceiling (STORY-AWS.md). Jenkins + agents may not fit."

c_hdr "1/6 credentials for this tier ($STATE/creds.env)"
if [[ ! -f "$STATE/creds.env" ]]; then
  umask 077
  { echo "JENKINS_PASSWORD=$(openssl rand -hex 12)"; echo "GITEA_PASSWORD=$(openssl rand -hex 12)"; } > "$STATE/creds.env"
  umask 022
fi
# shellcheck disable=SC1091
source "$STATE/creds.env"

c_hdr "2/6 Gitea in the cluster"
sed -e "s|IMAGE_PLACEHOLDER|$GITEA_IMAGE|" \
    -e "s|http://localhost:30300/|http://localhost:$GITEA_PF_PORT/|" \
    "$PG_ROOT/setup/gitea.yaml" | K apply -f - >/dev/null
K -n git rollout status deploy/gitea --timeout=300s >/dev/null
gitea_forward || die "port-forward to Gitea failed ($STATE/logs/gitea-pf.log)"
if ! gitea_api GET /user >/dev/null 2>&1; then
  K -n git exec deploy/gitea -- gitea admin user create --admin --username dev \
    --password "$GITEA_PASSWORD" --email dev@playground.local --must-change-password=false >/dev/null
fi
for org in platform payments; do
  gitea_api GET "/orgs/$org" >/dev/null 2>&1 || \
    gitea_api POST /orgs "{\"username\":\"$org\",\"visibility\":\"public\"}" >/dev/null
done
PLAYGROUND_STATE="$STATE" PLAYGROUND_GITEA_URL="$GITEA_URL" "$PG_ROOT/setup/seed.sh"
c_ok "$GITEA_URL (port-forward; dev / see creds.env)"

c_hdr "3/6 ECR repository + node-role push (what scripts/jenkins-install.sh does)"
aws ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$ECR_REPO" \
    --image-scanning-configuration scanOnPush=true >/dev/null
aws ecr put-lifecycle-policy --repository-name "$ECR_REPO" --lifecycle-policy-text \
  '{"rules":[{"rulePriority":1,"description":"keep last 10","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},"action":{"type":"expire"}}]}' >/dev/null
# Every pod on the node inherits this -- the honest caveat drill 14 is about.
aws iam attach-role-policy --role-name "$NODE_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
c_ok "$(ecr_registry)/$ECR_REPO, $NODE_ROLE may push"

c_hdr "4/6 Jenkins (lab chart + JCasC, Gitea overlay)"
K create namespace jenkins --dry-run=client -o yaml | K apply -f - >/dev/null
K apply -f "$LAB_ROOT/ci/jenkins/rbac.yaml" >/dev/null
helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update jenkins >/dev/null
helm upgrade --install jenkins jenkins/jenkins \
  --kubeconfig "$EKS_KUBECONFIG" --kube-context "$CTX" -n jenkins \
  --version "$JENKINS_CHART" \
  -f "$LAB_ROOT/ci/jenkins/values.yaml" \
  -f "$PG_ROOT/setup/jenkins-values-aws.yaml" \
  --set-string controller.admin.password="$JENKINS_PASSWORD" \
  --wait --timeout 15m >/dev/null
NODE_IP=$(K get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
printf 'NODE_IP=%s\n' "$NODE_IP" > "$STATE/aws.env"
load_creds
for _ in $(seq 1 60); do jenkins_get /api/json >/dev/null 2>&1 && break; sleep 5; done
jenkins_get /api/json >/dev/null 2>&1 || die "Jenkins not answering on $JENKINS_URL (NodePort 30094 open in terraform/eks?)"
c_ok "$JENKINS_URL (admin / see $STATE/creds.env)"

c_hdr "5/6 your workspace: $WORK"
cred_file="$STATE/git-credentials"
umask 077; printf 'http://dev:%s@localhost%%3a%s\n' "$GITEA_PASSWORD" "$GITEA_PF_PORT" > "$cred_file"; umask 022
for repo in platform/platform-lib payments/demo-api; do
  d="$WORK/${repo#*/}"
  if [[ ! -d "$d/.git" ]]; then
    git clone -q "http://dev@localhost:$GITEA_PF_PORT/$repo.git" "$d" \
      -c credential.helper="store --file=$cred_file"
    git -C "$d" config user.name "You (platform team)"
    git -C "$d" config user.email "you@playground.local"
  fi
  c_ok "$d"
done

c_hdr "6/6 baseline build (Gitea -> Jenkins -> ECR -> EKS)"
b=$(build_main_and_wait 900) || die "baseline build did not finish in 15 min"
[[ $(jq -r .result <<<"$b") == SUCCESS ]] || die "baseline build failed: $b -- $JENKINS_URL/job/demo-api/job/main/lastBuild/console"
img=$(K -n demo-ci get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}')
c_ok "build $b, running $img"
cat <<EOF

  AWS tier ready.   playground/play start --tier aws     (or: play start 11)
  After a drill:    playground/play reset                (runs up-aws.sh --reset for AWS drills)

  Jenkins   $JENKINS_URL
  Gitea     $GITEA_URL   (port-forward, kept alive by the drills)
  kubectl   --kubeconfig $EKS_KUBECONFIG
EOF
