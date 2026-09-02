#!/usr/bin/env bash
# Expose Argo CD's webhook endpoint and register it with GitHub, to replace
# polling with a push.
#
#   ./scripts/argocd-webhook.sh            expose it, print what is left to do
#   ./scripts/argocd-webhook.sh --test     prove it works, WITHOUT GitHub
#   ./scripts/argocd-webhook.sh --apply    also register the hook (needs gh)
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/versions.env"
CLUSTER="${CLUSTER:-andrei-lab-eks}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CLUSTER}"
K="kubectl --context $CLUSTER"
REPO="${REPO:-$REPO_SLUG}"
NODEPORT="${NODEPORT:-30083}"
APPLY=false; TEST=false
case "${1:-}" in
  --apply) APPLY=true ;;
  --test)  TEST=true  ;;
esac

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

# HTTPS, on the second NodePort. The plain-HTTP port is NOT usable: argocd-server
# answers it with a 307 redirect to HTTPS, and GitHub does not follow redirects
# for webhook delivery -- it records the 307 as the response and moves on. The
# hook shows as "delivered", Argo CD never hears about it, and nothing anywhere
# reports an error. Measured: HTTP 307 on :30083, HTTP 200 on :30084.
#
# The certificate is argocd-server's self-signed one, so the hook needs
# insecure_ssl=1. In production this is an Ingress with a real certificate;
# insecure_ssl on a public endpoint means the payload is confidential only by
# obscurity, and the HMAC is doing all the actual work.
HOOK_PORT=$((NODEPORT+1))
HOOK_URL="https://$NODE_IP:$HOOK_PORT/api/webhook"
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
echo "==> opening $NODEPORT/$HOOK_PORT on $SG to GitHub's hook ranges"
HOOK_CIDRS="$(curl -s https://api.github.com/meta | python3 -c 'import sys,json;print(" ".join(c for c in json.load(sys.stdin)["hooks"] if ":" not in c))')"
echo "    GitHub publishes its hook source ranges at api.github.com/meta:"
echo "    $HOOK_CIDRS"
for cidr in $HOOK_CIDRS; do
  for port in "$NODEPORT" "$HOOK_PORT"; do
    aws ec2 authorize-security-group-ingress --group-id "$SG" \
      --protocol tcp --port "$port" --cidr "$cidr" >/dev/null 2>&1 || true
  done
done
echo "    rules added (idempotent)"

# ---------------------------------------------------------------------------
# 3b. Prove the endpoint works WITHOUT involving GitHub.
#
# Worth doing separately, because the two things that break here fail in
# completely different places: reachability is an AWS problem and the signature
# is an Argo CD problem, and "the hook does not work" does not distinguish them.
#
# Signing is done in python rather than `openssl dgst`, because the body has to
# be byte-identical between what is signed and what is sent -- passing JSON
# through shell quoting and back is exactly how that stops being true.
# ---------------------------------------------------------------------------
if $TEST; then
  echo
  echo "==> sending a signed push event from this machine"
  python3 - "$SECRET" "$NODE_IP" "$HOOK_PORT" "$REPO" <<'PYEOF'
import sys, hmac, hashlib, json, ssl, urllib.request, urllib.error
secret, ip, port, repo = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
body = json.dumps({
    "ref": "refs/heads/main",
    "repository": {"html_url": f"https://github.com/{repo}", "default_branch": "main"},
}).encode()
sig = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
req = urllib.request.Request(
    f"https://{ip}:{port}/api/webhook", data=body, method="POST",
    headers={"X-GitHub-Event": "push", "Content-Type": "application/json",
             "X-Hub-Signature-256": sig})
try:
    r = urllib.request.urlopen(req, context=ssl._create_unverified_context(), timeout=15)
    print(f"    HTTP {r.status} -- accepted")
except urllib.error.HTTPError as e:
    print(f"    HTTP {e.code} -- {e.read().decode()[:120]}")
    print("    400 with a correct signature usually means argocd-server is still")
    print("    running with the OLD secret; it caches it and re-reads on restart.")
except Exception as e:
    print(f"    unreachable: {e}")
    print("    that is the security group or the NodePort, not the signature.")
PYEOF
  echo "    argocd-server should have logged a refresh:"
  $K -n argocd logs deploy/argocd-server --since=30s 2>/dev/null \
    | grep -i 'refresh' | tail -3 | sed 's/^/      /'
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
    -f config[insecure_ssl]=1 >/dev/null
  echo "    created"
else
  cat <<EOF

The endpoint is live. Registering it with GitHub needs the gh CLI, or two
clicks in the UI -- Settings -> Webhooks -> Add webhook:

  Payload URL   $HOOK_URL
  Content type  application/json
  Secret        $SECRET
  SSL           disable verification (self-signed cert, see above)
  Events        just the push event

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
