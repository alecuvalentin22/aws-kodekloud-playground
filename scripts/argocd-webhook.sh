#!/usr/bin/env bash
# Expose Argo CD's webhook endpoint and register it with GitHub, to replace
# polling with a push.
#
#   ./scripts/argocd-webhook.sh            print what it would do
#   ./scripts/argocd-webhook.sh --apply    actually create the GitHub webhook
#
# ---------------------------------------------------------------------------
# What this is worth, in numbers
#
# Argo CD polls the repository every 180s by default. Measured git-to-live in
# this lab: 155s, almost all of it waiting for the next poll. The reconcile
# itself is fast; the LATENCY IS THE POLL, and no amount of tuning the sync
# makes it better.
#
# A webhook makes GitHub tell Argo CD the moment a push lands. The poll stays as
# a backstop -- and it must, because a webhook is best-effort delivery: GitHub
# retries, but a webhook that fails while Argo CD is restarting is simply lost.
# A GitOps controller that ONLY reacts to webhooks will silently sit on stale
# state forever. Push for speed, poll for correctness.
# ---------------------------------------------------------------------------
set -euo pipefail

CLUSTER="${CLUSTER:-andrei-lab-eks}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/andrei-lab-eks}"
K="kubectl --context $CLUSTER"
REPO="${REPO:-alecuvalentin22/aws-kodekloud-playground}"
NODEPORT="${NODEPORT:-30083}"
APPLY=false
[[ "${1:-}" == "--apply" ]] && APPLY=true

# ---------------------------------------------------------------------------
# 1. Argo CD's webhook endpoint has to be reachable FROM GitHub.
#
# This is where a playground usually loses. There is no ingress with a real
# hostname and no TLS certificate, and `kubectl port-forward` binds to
# localhost, which GitHub cannot reach. What IS available: a NodePort on an
# instance with a public IP, and a security group we control.
#
# So this works here -- but only because the lab explicitly accepts a publicly
# reachable, unauthenticated-by-TLS endpoint. Do not copy this shape into
# anything real: use an Ingress with TLS, and keep the shared secret.
# ---------------------------------------------------------------------------
echo "==> exposing argocd-server on NodePort $NODEPORT"
$K -n argocd patch svc argocd-server -p "{
  \"spec\": {
    \"type\": \"NodePort\",
    \"ports\": [
      {\"name\":\"http\",\"port\":80,\"targetPort\":8080,\"nodePort\":$NODEPORT},
      {\"name\":\"https\",\"port\":443,\"targetPort\":8080,\"nodePort\":$((NODEPORT+1))}
    ]
  }
}" >/dev/null

NODE_IP="$($K get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
[[ -n "$NODE_IP" ]] || { echo "no node ExternalIP -- cannot expose a webhook" >&2; exit 1; }
HOOK_URL="http://$NODE_IP:$NODEPORT/api/webhook"
echo "    endpoint: $HOOK_URL"

# ---------------------------------------------------------------------------
# 2. The shared secret. Argo CD reads it from the argocd-secret Secret under the
# key `webhook.github.secret`, and it is the ONLY thing standing between this
# endpoint and anyone on the internet triggering a refresh.
#
# Without it Argo CD accepts unsigned payloads, which on a public NodePort means
# a stranger can force repository refreshes -- cheap, but a free DoS against the
# repo-server and a way to make the controller hammer GitHub until it is rate
# limited.
# ---------------------------------------------------------------------------
SECRET="$(openssl rand -hex 20)"
echo "==> setting webhook.github.secret on argocd-secret"
$K -n argocd patch secret argocd-secret \
  -p "{\"stringData\":{\"webhook.github.secret\":\"$SECRET\"}}" >/dev/null
# argocd-server caches the secret; it re-reads on restart.
$K -n argocd rollout restart deploy/argocd-server >/dev/null
$K -n argocd rollout status  deploy/argocd-server --timeout=300s

# ---------------------------------------------------------------------------
# 3. The security group. The node SG admits the cluster and your /32; GitHub's
# hook runners are neither.
# ---------------------------------------------------------------------------
SG="$(aws eks describe-cluster --name "$CLUSTER" \
        --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
echo "==> opening $NODEPORT on $SG to GitHub's hook ranges"
HOOK_CIDRS="$(curl -s https://api.github.com/meta | python3 -c 'import sys,json;print(" ".join(c for c in json.load(sys.stdin)["hooks"] if ":" not in c))')"
echo "    GitHub publishes its hook source ranges at api.github.com/meta:"
echo "    $HOOK_CIDRS"
if $APPLY; then
  for cidr in $HOOK_CIDRS; do
    aws ec2 authorize-security-group-ingress --group-id "$SG" \
      --protocol tcp --port "$NODEPORT" --cidr "$cidr" >/dev/null 2>&1 || true
  done
  echo "    rules added"
else
  echo "    (dry run -- would add $(echo "$HOOK_CIDRS" | wc -w | tr -d ' ') rules)"
fi

# ---------------------------------------------------------------------------
# 4. Register the hook.
# ---------------------------------------------------------------------------
if $APPLY; then
  command -v gh >/dev/null || { echo "gh CLI not on PATH; create the hook by hand" >&2; exit 1; }
  echo "==> creating the webhook on $REPO"
  gh api "repos/$REPO/hooks" -X POST \
    -f name=web \
    -F active=true \
    -f 'events[]=push' \
    -f config[url]="$HOOK_URL" \
    -f config[content_type]=json \
    -f config[secret]="$SECRET" \
    -f config[insecure_ssl]=0 >/dev/null
  echo "    created"
else
  cat <<EOF

Dry run. To create it:

  ./scripts/argocd-webhook.sh --apply

Then measure the difference -- that is the point:

  ./scripts/scenario run 04 --only argocd     # before: ~155s
  # push a commit, and watch
  kubectl -n argocd get app demo-argocd -w
EOF
fi

cat <<EOF

Verify delivery from GitHub's side, not from hope:
  gh api repos/$REPO/hooks --jq '.[] | {id, url: .config.url, last: .last_response}'

A 'last_response.code' of 200 means Argo CD accepted it. 403 means the shared
secret does not match. A timeout means the security group or the NodePort is
wrong -- and Argo CD will look completely healthy while it happens, because
from its side nothing arrived.
EOF
