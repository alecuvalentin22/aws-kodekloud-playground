#!/usr/bin/env bash
# Send the AWS tier's local files to the home-lab box, from the Mac that has them.
#
#   homelab/mac/send-aws.sh                everything below, then three checks on the box
#   homelab/mac/send-aws.sh --creds-only   just the KodeKloud keys (new session, rest already there)
#
# Copies, creating directories 700 and files 600:
#   ~/.config/platform-lab/aws-lab-creds.env            the KodeKloud keys
#   ~/.local/state/platform-lab-playground/aws/creds.env, aws.env
#                                                      the AWS tier's Jenkins/Gitea logins + node IP
#   ~/.kube/andrei-lab-eks                              the EKS kubeconfig
#   terraform/eks/terraform.tfvars   (if present; git-ignored; `make eks` from the box needs it)
# Not sent: scores, verification files, current.env, the aws-lane-* dirs.
# Never prints a value, only file names. Never touches ~/.aws.
#
# Then on the box: aws sts get-caller-identity (account), kubectl get nodes (count)
# against EKS, and playground/lib/preflight-aws.sh (the check `play start` runs).
# The EKS API only admits the home's public IP; the box shares the Mac's, so it works.
#
# HOMELAB_SSH_WSL  ssh alias of the Ubuntu box (default: homelab-1-wsl)
set -euo pipefail
WSL="${HOMELAB_SSH_WSL:-homelab-1-wsl}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CREDS_ONLY=no
case "${1:-}" in
  "") ;;
  --creds-only) CREDS_ONLY=yes ;;
  *) sed -n '2,6p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
esac

LOCAL_CREDS="${AWS_CREDS_FILE:-$HOME/.config/platform-lab/aws-lab-creds.env}"
LOCAL_STATE="${PLAYGROUND_AWS_STATE:-$HOME/.local/state/platform-lab-playground/aws}"
LOCAL_KUBE="${EKS_KUBECONFIG:-$HOME/.kube/andrei-lab-eks}"
LOCAL_TFVARS="$REPO/terraform/eks/terraform.tfvars"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
FAILED=0

SSH=(ssh -n -o BatchMode=yes -o ConnectTimeout=15 "$WSL")
"${SSH[@]}" 'exit 0' || { echo "ssh $WSL does not work from this Mac (see homelab/mac/join.sh)" >&2; exit 1; }

# send <local file> <remote path relative to $HOME>
send() {
  local src=$1 dst=$2 dir
  dir=$(dirname "$dst")
  if [[ ! -f $src ]]; then bad "$(basename "$src"): not found on this Mac ($src)"; FAILED=1; return; fi
  "${SSH[@]}" "install -d -m 700 \"\$HOME/$dir\" && chmod 700 \"\$HOME/$dir\"" \
    && scp -p -q -o BatchMode=yes "$src" "$WSL:$dst" \
    && "${SSH[@]}" "chmod 600 \"\$HOME/$dst\"" \
    && ok "$dst" || { bad "$dst: copy failed"; FAILED=1; }
}

echo "Sending to $WSL"
send "$LOCAL_CREDS" .config/platform-lab/aws-lab-creds.env
if [[ $CREDS_ONLY == no ]]; then
  send "$LOCAL_STATE/creds.env" .local/state/platform-lab-playground/aws/creds.env
  send "$LOCAL_STATE/aws.env"   .local/state/platform-lab-playground/aws/aws.env
  send "$LOCAL_KUBE"            .kube/andrei-lab-eks
  if [[ -f $LOCAL_TFVARS ]]; then
    "${SSH[@]}" '[ -d "$HOME/platform-lab/terraform/eks" ]' \
      && send "$LOCAL_TFVARS" platform-lab/terraform/eks/terraform.tfvars \
      || { bad "terraform.tfvars: ~/platform-lab/terraform/eks missing on the box (git pull there first)"; FAILED=1; }
  else
    echo "  - terraform.tfvars: none on this Mac, skipped"
  fi
fi

echo "Checks on $WSL"
# Remote prologue: the lab keys in this shell's environment only (never ~/.aws).
ENVSH='set -a; . "$HOME/.config/platform-lab/aws-lab-creds.env"; set +a; unset AWS_PROFILE;
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}" AWS_REGION="${AWS_REGION:-us-east-1}";'

if acct=$("${SSH[@]}" "$ENVSH aws sts get-caller-identity --query Account --output text" 2>/dev/null); then
  ok "aws sts get-caller-identity: account $acct"
else
  bad "aws sts get-caller-identity failed (keys expired? new KodeKloud session: run with --creds-only after updating the Mac's file)"; FAILED=1
fi

if true; then
  if n=$("${SSH[@]}" "$ENVSH timeout 60 kubectl --kubeconfig \"\$HOME/.kube/andrei-lab-eks\" --context andrei-lab-eks get nodes --no-headers 2>/dev/null | wc -l"); [[ ${n:-0} -gt 0 ]]; then
    ok "kubectl get nodes (EKS): $n node(s)"
  else
    bad "kubectl get nodes: no answer (EKS gone, or the box's public IP is not in public_access_cidrs)"; FAILED=1
  fi
fi

# lib/aws.sh's gitea_forward probes http://localhost:31300 with a curl that has no
# timeout; in WSL that connect is silently dropped, so with no forward running the
# preflight hangs. Start the same port-forward first (it is what gitea_forward does).
"${SSH[@]}" "$ENVSH S=\"\$HOME/.local/state/platform-lab-playground/aws\";
  curl -fsS -m 3 -o /dev/null http://localhost:31300/api/healthz 2>/dev/null && exit 0;
  mkdir -p \"\$S/logs\" && chmod 700 \"\$S\";
  nohup kubectl --kubeconfig \"\$HOME/.kube/andrei-lab-eks\" --context andrei-lab-eks -n git port-forward svc/gitea 31300:3000 >\"\$S/logs/gitea-pf.log\" 2>&1 &
  echo \$! > \"\$S/gitea-pf.pid\"; sleep 4" >/dev/null 2>&1 || true

if out=$("${SSH[@]}" 'timeout 120 "$HOME/platform-lab/playground/lib/preflight-aws.sh" 2>&1' 2>/dev/null); then
  ok "preflight-aws: $(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g; s/^ *[✓✗] *//' | tail -1)"
else
  bad "preflight-aws: $(printf '%s' "${out:-no output (is ~/platform-lab updated on the box?)}" | sed 's/\x1b\[[0-9;]*m//g; s/^ *[✓✗] *//' | tail -1)"; FAILED=1
fi
exit $FAILED
