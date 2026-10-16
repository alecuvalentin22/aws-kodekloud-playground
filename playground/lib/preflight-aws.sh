#!/usr/bin/env bash
# Is the AWS tier ready for a drill? `play start` runs this before any drill
# with NEEDS=aws. Exits non-zero with ONE line saying what to do.
set -uo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/aws.sh"

fail() { c_bad "$*"; exit 1; }

[[ -r "$AWS_CREDS_FILE" ]] || fail "No AWS lab credentials: put KEY=value lines in $AWS_CREDS_FILE (mode 600)."
aws_env
acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || fail "AWS credentials rejected (expired playground?). Paste fresh keys into $AWS_CREDS_FILE."

# The playground's IAM window (AGENTS.md, "The IAM window is time-boxed"):
# every statement in AWS_EKSECSWithConditions carries DateLessThan. When it
# passes, API calls fail with AccessDenied while instances keep running --
# a drill started then would be a drill about the clock. Not a playground
# account (no such policy)? Then there is no window to check.
doc=$(aws iam get-policy-version --policy-arn "arn:aws:iam::$acct:policy/AWS_EKSECSWithConditions" \
        --version-id v1 --query PolicyVersion.Document --output json 2>/dev/null || true)
if [[ -n $doc ]]; then
  end=$(jq -r '[.. | objects | .DateLessThan? | objects | ."aws:CurrentTime"? | strings] | first // empty' <<<"$doc")
  if [[ -n $end ]]; then
    end_s=$(python3 -c 'import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' "$end")
    left=$(( (end_s - $(date +%s)) / 60 ))
    (( left > 0 )) || fail "The playground's IAM window closed at $end. Start a new playground session."
    (( left >= 20 )) || fail "Only $left min left in the IAM window (closes $end): not enough for a drill."
  fi
fi

[[ -f "$EKS_KUBECONFIG" ]] || fail "No kubeconfig at $EKS_KUBECONFIG. Build the lab: make eks (or make kubeconfig)."
K get nodes >/dev/null 2>&1 || fail "EKS cluster $EKS_CLUSTER unreachable with $EKS_KUBECONFIG."
[[ -f "$STATE/creds.env" && -f "$STATE/aws.env" ]] || fail "AWS tier not installed on this cluster yet. Run: playground/setup/up-aws.sh"
K -n git get deploy gitea >/dev/null 2>&1 || fail "No Gitea on $EKS_CLUSTER (new cluster?). Run: playground/setup/up-aws.sh"
load_creds
gitea_forward || fail "Cannot reach the EKS Gitea through port-forward on :$GITEA_PF_PORT ($STATE/logs/gitea-pf.log)."
jenkins_get /api/json >/dev/null 2>&1 || fail "Jenkins not answering on $JENKINS_URL (node IP changed? re-run setup/up-aws.sh)."
c_ok "AWS tier ready: account $acct, ${left:-?} min left in the IAM window"
