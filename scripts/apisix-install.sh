#!/usr/bin/env bash
# Apache APISIX -- gateway, etcd and ingress controller -- alongside Kong.
#
#   ./scripts/apisix-install.sh        # or: make apisix
#
# Kong stays. The side-by-side is the point, exactly as Argo CD and Flux both
# reconcile the same repo: same demo workload, same auth requirement, same rate
# limit, so any difference observed is a property of the gateway.
#
# See kubernetes/apisix/README.md for the architecture -- in particular that
# apisix-ingress-controller 2.x does NOT write to etcd. It pushes through the
# Admin API via an ADC sidecar, which is different from every v1.x tutorial.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-andrei-lab-eks}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CLUSTER}"
K="kubectl --context $CLUSTER"
NS="${APISIX_NS:-apisix}"
APISIX_CHART="${APISIX_CHART:-2.17.0}"          # app 3.18.0
AIC_CHART="${AIC_CHART:-1.3.0}"                 # app 2.2.0

command -v helm >/dev/null || { echo "helm not on PATH" >&2; exit 1; }

helm repo add apisix https://charts.apiseven.com >/dev/null 2>&1 || true
helm repo update apisix >/dev/null

# ---------------------------------------------------------------------------
# The Admin API key.
#
# APISIX ships a well-known default admin key, and every tutorial leaves it in
# place. It is a single static bearer token that authorises rewriting every
# route in the gateway -- so it is generated here and kept in a Secret, and the
# Admin API is never given a NodePort. That is the JD2-APISIX-5 line
# ("secure configuration, access-control") being answered with a decision
# rather than a sentence.
# ---------------------------------------------------------------------------
$K create namespace "$NS" --dry-run=client -o yaml | $K apply -f - >/dev/null
if ! $K -n "$NS" get secret apisix-admin >/dev/null 2>&1; then
  ADMIN_KEY="$(openssl rand -hex 24)"
  $K -n "$NS" create secret generic apisix-admin --from-literal=key="$ADMIN_KEY" >/dev/null
  echo "==> generated a new Admin API key (stored in secret/apisix-admin)"
else
  ADMIN_KEY="$($K -n "$NS" get secret apisix-admin -o jsonpath='{.data.key}' | base64 -d)"
  echo "==> reusing the existing Admin API key"
fi

# ---------------------------------------------------------------------------
# Gateway + etcd. HA from the start, because scenario 14 disrupts these on
# purpose and a single-replica gateway cannot show the difference between a
# control-plane stall and a data-plane one.
#
# maxSurge 0 / maxUnavailable 1 mirrors the production rollout discipline in
# the rest of this repo: never add capacity you have not proven, take one out
# at a time.
# ---------------------------------------------------------------------------
echo "==> APISIX gateway $APISIX_CHART (3 replicas) + etcd (3 members)"
helm upgrade --install apisix apisix/apisix \
  --kube-context "$CLUSTER" \
  --namespace "$NS" \
  --version "$APISIX_CHART" \
  --set apisix.deployment.mode=traditional \
  --set service.type=NodePort \
  --set service.http.nodePort=30093 \
  --set replicaCount=3 \
  --set updateStrategy.type=RollingUpdate \
  --set updateStrategy.rollingUpdate.maxSurge=0 \
  --set updateStrategy.rollingUpdate.maxUnavailable=1 \
  --set podDisruptionBudget.enabled=true \
  --set podDisruptionBudget.minAvailable=2 \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=128Mi \
  --set apisix.prometheus.enabled=true \
  --set metrics.serviceMonitor.enabled=true \
  --set metrics.serviceMonitor.namespace="$NS" \
  --set-string apisix.admin.credentials.admin="$ADMIN_KEY" \
  --set apisix.admin.allow.ipList[0]=0.0.0.0/0 \
  --set etcd.enabled=true \
  --set etcd.replicaCount=3 \
  --set etcd.resources.requests.cpu=50m \
  --set etcd.resources.requests.memory=128Mi \
  --wait --timeout 15m

# admin.allow.ipList is 0.0.0.0/0 and that is NOT a contradiction of the note
# above: it means "any pod inside the cluster", because the Admin API Service is
# ClusterIP and unreachable from outside. Narrowing it further would block the
# ingress controller, which is exactly the client that needs it.

# Spread the gateway across nodes. Done as a patch rather than a chart value
# because the chart's affinity key differs between versions, and a silently
# ignored affinity block is worse than an explicit patch.
$K -n "$NS" patch deploy apisix --type=merge -p '{"spec":{"template":{"spec":{
  "topologySpreadConstraints":[{"maxSkew":1,"topologyKey":"kubernetes.io/hostname",
  "whenUnsatisfiable":"ScheduleAnyway","labelSelector":{"matchLabels":{"app.kubernetes.io/name":"apisix"}}}]}}}}' >/dev/null
$K -n "$NS" rollout status deploy/apisix --timeout=300s

# ---------------------------------------------------------------------------
# Ingress controller. 2.x, so it talks to the Admin API, not to etcd.
# ---------------------------------------------------------------------------
echo "==> apisix-ingress-controller $AIC_CHART"
helm upgrade --install apisix-ingress-controller apisix/apisix-ingress-controller \
  --kube-context "$CLUSTER" \
  --namespace "$NS" \
  --version "$AIC_CHART" \
  --set deployment.replicas=1 \
  --set deployment.resources.requests.cpu=25m \
  --set deployment.resources.requests.memory=64Mi \
  --set config.provider.syncPeriod=1m \
  --set config.kubernetes.ingressClass=apisix \
  --wait --timeout 10m

echo
echo "==> what is running"
$K -n "$NS" get pods -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,NODE:.spec.nodeName' --no-headers
echo
echo "==> gateway spread across nodes: $($K -n "$NS" get pods -l app.kubernetes.io/name=apisix -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l | tr -d ' ') distinct"

cat <<EOF

  APISIX gateway   http://<node-ip>:30093
  Admin API        NOT exposed, on purpose. Reach it with:
                   kubectl -n $NS port-forward svc/apisix-admin 9180:9180
                   curl -H "X-API-KEY: \$(kubectl -n $NS get secret apisix-admin -o jsonpath='{.data.key}' | base64 -d)" \\
                        http://127.0.0.1:9180/apisix/admin/routes

Next: kubectl apply -f kubernetes/apisix/demo/
EOF
