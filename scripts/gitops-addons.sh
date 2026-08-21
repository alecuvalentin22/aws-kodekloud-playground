#!/usr/bin/env bash
# Everything that sits ON TOP of Argo CD and Flux.
#
#   ./scripts/gitops-addons.sh              install all
#   ./scripts/gitops-addons.sh nginx rollouts   install a subset
#
# Run AFTER ./scripts/gitops-install.sh. Split out rather than folded in,
# because these are optional in a way the two GitOps controllers are not --
# and because they are what pushed the cluster past the pod ceiling. The order
# below is dependency order, not alphabetical.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-andrei-lab-eks}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CLUSTER}"
K="kubectl --context $CLUSTER"

ROLLOUTS_VERSION="${ROLLOUTS_VERSION:-v1.9.1}"
FLAGGER_VERSION="${FLAGGER_VERSION:-1.44.0}"
NGINX_VERSION="${NGINX_VERSION:-4.15.1}"
SEALED_VERSION="${SEALED_VERSION:-2.19.3}"
FLUXOP_VERSION="${FLUXOP_VERSION:-v0.58.1}"

WANT="${*:-nginx rollouts flagger sealed-secrets flux-operator}"
want() { [[ " $WANT " == *" $1 "* ]]; }

# ---------------------------------------------------------------------------
# ingress-nginx -- a PREREQUISITE, not a nice-to-have.
#
# Both Argo Rollouts' canary weights and Flagger's traffic shifting are
# implemented as annotations on an Ingress. Without an ingress controller
# reading them, Rollouts silently degrades to weight-by-replica-count and
# Flagger cannot start at all. This is the dependency that made every earlier
# progressive-delivery measurement approximate.
# ---------------------------------------------------------------------------
if want nginx; then
  echo "==> ingress-nginx $NGINX_VERSION"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update ingress-nginx >/dev/null
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --kube-context "$CLUSTER" \
    --namespace ingress-nginx --create-namespace \
    --version "$NGINX_VERSION" \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=30090 \
    --set controller.service.nodePorts.https=30443 \
    --set controller.replicaCount=1 \
    --set controller.resources.requests.cpu=50m \
    --set controller.resources.requests.memory=128Mi \
    --set controller.admissionWebhooks.enabled=false \
    --set controller.metrics.enabled=true \
    --set controller.podAnnotations."prometheus\.io/scrape"=true \
    --set controller.podAnnotations."prometheus\.io/port"=10254 \
    --wait --timeout 10m
  # ---------------------------------------------------------------------------
  # metrics.enabled=true is REQUIRED by Flagger, and it is off by default.
  #
  # This is what actually stopped Flagger's analysis completing on the earlier
  # attempt -- not capacity, which was the first guess. Flagger's nginx provider
  # computes request-success-rate from `nginx_ingress_controller_requests`. With
  # metrics disabled the controller never exports that series, the PromQL
  # returns an empty vector, and Flagger reports:
  #
  #   Halt advancement no values found for nginx metric request-success-rate
  #
  # which reads like a Flagger problem and is an ingress-nginx setting.
  #
  # The podAnnotations matter just as much: Flagger's bundled Prometheus
  # discovers targets with a `kubernetes-pods` job that keeps only pods
  # annotated prometheus.io/scrape=true. Enabling the metrics port without
  # advertising it leaves the series unexported just the same.
  # ---------------------------------------------------------------------------
  # admissionWebhooks disabled on purpose. A ValidatingWebhookConfiguration is
  # cluster-scoped and outlives its pods: if the controller is evicted on a
  # tight node, EVERY Ingress apply cluster-wide starts failing, including the
  # ones Argo Rollouts and Flagger create mid-rollout. On a 3-node lab that
  # turns a capacity blip into an unrelated-looking outage. Keep it on in
  # production, where the controller is not the thing being evicted.
fi

# ---------------------------------------------------------------------------
# Argo Rollouts -- the CONTROLLER. Note it goes in its own namespace and is
# entirely independent of Argo CD; you can run Rollouts with no Argo CD at all,
# and this lab does exactly that for the Flux-side comparison to be fair.
# ---------------------------------------------------------------------------
if want rollouts; then
  echo "==> argo-rollouts $ROLLOUTS_VERSION"
  $K create namespace argo-rollouts --dry-run=client -o yaml | $K apply -f - >/dev/null
  $K apply -n argo-rollouts --server-side --force-conflicts \
    -f "https://github.com/argoproj/argo-rollouts/releases/download/${ROLLOUTS_VERSION}/install.yaml" >/dev/null
  $K -n argo-rollouts rollout status deploy/argo-rollouts --timeout=600s
fi

# ---------------------------------------------------------------------------
# Flagger + its load tester.
#
# The load tester is not optional decoration. Flagger promotes on METRICS, and
# metrics need requests: a canary with no traffic produces no signal, so the
# analysis neither passes nor fails and the rollout stalls until
# progressDeadlineSeconds. In production the traffic is real; in a lab
# something has to generate it.
# ---------------------------------------------------------------------------
if want flagger; then
  echo "==> flagger $FLAGGER_VERSION"
  helm repo add flagger https://flagger.app >/dev/null 2>&1 || true
  helm repo update flagger >/dev/null
  $K apply -f "https://raw.githubusercontent.com/fluxcd/flagger/v${FLAGGER_VERSION}/artifacts/flagger/crd.yaml" >/dev/null
  helm upgrade --install flagger flagger/flagger \
    --kube-context "$CLUSTER" \
    --namespace ingress-nginx \
    --version "$FLAGGER_VERSION" \
    --set meshProvider=nginx \
    --set metricsServer=http://flagger-prometheus.ingress-nginx:9090 \
    --set prometheus.install=true \
    --set resources.requests.cpu=25m \
    --set resources.requests.memory=64Mi \
    --wait --timeout 10m

  echo "==> flagger load tester"
  $K create namespace demo-flagger --dry-run=client -o yaml | $K apply -f - >/dev/null
  helm upgrade --install flagger-loadtester flagger/loadtester \
    --kube-context "$CLUSTER" \
    --namespace demo-flagger \
    --set resources.requests.cpu=25m \
    --set resources.requests.memory=32Mi \
    --wait --timeout 5m
fi

# ---------------------------------------------------------------------------
# Sealed Secrets, in kube-system and named sealed-secrets-controller.
#
# Both of those are kubeseal's built-in defaults for --controller-namespace and
# --controller-name. Install it anywhere else and every kubeseal invocation
# needs two extra flags, forever -- including the ones a colleague runs from
# their own laptop. The chart's default fullname is just "sealed-secrets", which
# does NOT match, so the override is load-bearing.
# ---------------------------------------------------------------------------
if want sealed-secrets; then
  echo "==> sealed-secrets $SEALED_VERSION"
  # bitnami.github.io, NOT bitnami-labs.github.io. The chart lives under a
  # different org than the source repository, and the bitnami-labs URL -- which
  # is what most blog posts still show -- returns 404.
  helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets >/dev/null 2>&1 || true
  helm repo update sealed-secrets >/dev/null
  helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
    --kube-context "$CLUSTER" \
    --namespace kube-system \
    --version "$SEALED_VERSION" \
    --set-string fullnameOverride=sealed-secrets-controller \
    --set resources.requests.cpu=20m \
    --set resources.requests.memory=64Mi \
    --wait --timeout 5m
fi

# ---------------------------------------------------------------------------
# Flux Operator. Installed ALONGSIDE the `flux install` controllers rather than
# replacing them -- adopting an existing flux-system with a FluxInstance is a
# real operation with real failure modes, and doing it here would invalidate
# five already-measured scenarios. The FluxInstance in gitops/flux-operator/ is
# applied separately, once you have decided to hand over.
# ---------------------------------------------------------------------------
if want flux-operator; then
  echo "==> flux-operator $FLUXOP_VERSION"
  $K apply --server-side --force-conflicts \
    -f "https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/${FLUXOP_VERSION}/install.yaml" >/dev/null
  $K -n flux-system rollout status deploy/flux-operator --timeout=600s
fi

echo
echo "==> pod pressure after addons"
$K get nodes -o custom-columns='NODE:.metadata.name,MAX_PODS:.status.allocatable.pods' --no-headers
echo "    pods running: $($K get pods -A --no-headers | grep -c Running)"
echo "    pods pending: $($K get pods -A --no-headers | grep -c Pending)"

cat <<EOF

  Flux Web UI     kubectl -n flux-system port-forward svc/flux-operator 9080:9080
                  http://localhost:9080
  Rollouts UI     kubectl argo rollouts dashboard -n demo-rollouts-nginx
                  http://localhost:3100
  ingress-nginx   NodePort 30090 on any node
EOF
