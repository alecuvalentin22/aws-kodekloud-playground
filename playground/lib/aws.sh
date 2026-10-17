# shellcheck shell=bash
# The AWS tier. Source AFTER lib/common.sh: it re-points the shared helpers
# (K, load_creds, the Jenkins/Gitea URLs, STATE) at the EKS lab, so drills
# 11+ use exactly the same as_teammate / jenkins_* / assert_main_green_since
# as the local drills.
#
#   source lib/common.sh; source lib/aws.sh
#
# The AWS tier keeps its OWN state, so it never touches the local tier's
# passwords, scratch clones or cookies:
#   STATE  ~/.local/state/platform-lab-playground/aws
#   WORK   ~/platform-playground-aws           (your clones of the EKS Gitea)

AWS_CREDS_FILE="${AWS_CREDS_FILE:-$HOME/.config/platform-lab/aws-lab-creds.env}"
EKS_CLUSTER="${EKS_CLUSTER:-andrei-lab-eks}"
EKS_KUBECONFIG="${EKS_KUBECONFIG:-$HOME/.kube/$EKS_CLUSTER}"
NODE_ROLE="${NODE_ROLE:-eksWorkerNodeRole}"
ECR_REPO=platform-lab/demo-api
# Not opened by terraform/eks (node_service_ports has no Gitea entry), so the
# EKS Gitea is reached through a kubectl port-forward on this port.
GITEA_PF_PORT=31300

STATE="${PLAYGROUND_STATE:-$HOME/.local/state/platform-lab-playground/aws}"
WORK="${PLAYGROUND_WORK:-$HOME/platform-playground-aws}"
JAR="$STATE/jenkins.cookies"
GITEA_URL="${PLAYGROUND_GITEA_URL:-http://localhost:$GITEA_PF_PORT}"

CTX="$EKS_CLUSTER"
K() { kubectl --kubeconfig "$EKS_KUBECONFIG" --context "$CTX" "$@"; }

# Lab credentials into the environment, never into ~/.aws/credentials
# (AGENTS.md: that file sits next to production profiles on this laptop).
aws_env() {
  [[ -r "$AWS_CREDS_FILE" ]] || die "No AWS lab credentials at $AWS_CREDS_FILE (mode 600, KEY=value lines)"
  set -a
  # shellcheck disable=SC1090
  source "$AWS_CREDS_FILE"
  set +a
  unset AWS_PROFILE
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}" AWS_REGION="${AWS_REGION:-us-east-1}"
}

aws_account() { aws sts get-caller-identity --query Account --output text; }
ecr_registry() { echo "$(aws_account).dkr.ecr.${AWS_REGION:-us-east-1}.amazonaws.com"; }

# common.sh's load_creds reads $STATE/creds.env -- with STATE re-pointed above
# that is the AWS tier's own file. This adds the lab creds and the Jenkins URL
# (a node's public IP, recorded by up-aws.sh) on top.
load_creds() {
  [[ -f "$STATE/creds.env" ]] || die "AWS tier not set up. Run: playground/setup/up-aws.sh"
  # shellcheck disable=SC1091
  source "$STATE/creds.env"
  GITEA_USER=${GITEA_USER:-dev}
  [[ -f "$STATE/aws.env" ]] && {
    # shellcheck disable=SC1091
    source "$STATE/aws.env"; }
  JENKINS_URL="${PLAYGROUND_JENKINS_URL:-http://${NODE_IP:-unknown-node-ip}:30094}"
  aws_env
  gitea_forward >/dev/null 2>&1 || true
}

# Keep one port-forward to the EKS Gitea alive, reused across commands.
gitea_forward() {
  curl -fsS -m 3 -o /dev/null "$GITEA_URL/api/healthz" 2>/dev/null && return 0
  [[ -f "$STATE/gitea-pf.pid" ]] && kill "$(cat "$STATE/gitea-pf.pid")" 2>/dev/null
  mkdir -p "$STATE/logs"
  nohup kubectl --kubeconfig "$EKS_KUBECONFIG" --context "$CTX" -n git \
    port-forward svc/gitea "$GITEA_PF_PORT:3000" >"$STATE/logs/gitea-pf.log" 2>&1 &
  echo $! > "$STATE/gitea-pf.pid"
  local _
  for _ in $(seq 1 20); do
    curl -fsS -m 3 -o /dev/null "$GITEA_URL/api/healthz" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

# Is the AWS tier usable right now? Quiet; for reset.sh guards, so a local
# `play reset` never fails because the EKS lab is gone.
aws_tier_up() {
  [[ -f "$STATE/creds.env" && -r "$AWS_CREDS_FILE" ]] || return 1
  # K needs the lab credentials too (the kubeconfig's exec plugin calls aws), so
  # both run in the subshell that loaded them. Before 2026-10-17 K ran outside it
  # and failed whenever the caller had not loaded them itself, so a drill's
  # reset.sh run on its own silently skipped everything.
  ( aws_env; aws sts get-caller-identity >/dev/null 2>&1 && K get ns jenkins >/dev/null 2>&1 )
}

# Console text of a build. jenkins_get prints the body; fine for big logs.
build_console() { jenkins_get "/job/demo-api/job/${2:-main}/$1/consoleText"; }
build_numbers() { jenkins_get "/job/demo-api/job/${1:-main}/api/json?tree=builds%5Bnumber%5D" | jq -r '.builds[].number'; }

# Trigger main and wait for it to finish. Prints {number,result}.
build_main_and_wait() {
  local limit=${1:-900} t0 before b
  t0=$(date +%s)
  before=$(jq -r '.number // 0' <<<"$(last_build main)")
  jenkins_post "$JENKINS_URL/job/demo-api/job/main/build?delay=0" >/dev/null 2>&1 || jenkins_scan
  while (( $(date +%s) - t0 < limit )); do
    b=$(last_build main)
    if (( $(jq -r '.number // 0' <<<"$b") > before )) && [[ $(jq -r '.building' <<<"$b") == false ]]; then
      jq -c '{number, result}' <<<"$b"; return 0
    fi
    sleep 10
  done
  return 1
}
