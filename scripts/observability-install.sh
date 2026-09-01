#!/usr/bin/env bash
# kube-prometheus-stack: Prometheus, Grafana, Alertmanager, node-exporter,
# kube-state-metrics.
#
#   ./scripts/observability-install.sh        # or: make observability
#
# A PREREQUISITE for the APISIX work, not a nice-to-have. Scenario 15's whole
# finding is that a broken canary is invisible in route-level metrics, and you
# cannot show that without somewhere to see the metrics.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-andrei-lab-eks}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CLUSTER}"
K="kubectl --context $CLUSTER"
KPS_VERSION="${KPS_VERSION:-88.6.2}"

command -v helm >/dev/null || { echo "helm not on PATH" >&2; exit 1; }

echo "==> kube-prometheus-stack $KPS_VERSION"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

# ---------------------------------------------------------------------------
# Sized for four t3.medium nodes, and the sizing is the interesting part.
#
# The stock chart assumes a real cluster: 50GiB of Prometheus storage, 10 days
# of retention, an Alertmanager cluster. Here the whole cluster has ~13 GiB of
# allocatable memory and it is already running Argo CD, Flux, Rollouts, Flagger
# and ingress-nginx. So:
#
#   retention 2h + no persistence  -> Prometheus stays well under 512Mi
#   scrapeInterval 30s             -> half the series churn of the 15s default
#   admissionWebhooks disabled     -> a ValidatingWebhookConfiguration is
#                                     cluster-scoped and outlives its pods. If
#                                     the operator is evicted on a tight node,
#                                     every ServiceMonitor apply cluster-wide
#                                     starts failing, including APISIX's.
#
# Retention of 2h is the honest trade: enough to watch a canary roll out and
# fail, useless for anything historical. Say that rather than implying this is
# a production monitoring stack.
# ---------------------------------------------------------------------------
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --kube-context "$CLUSTER" \
  --namespace observability --create-namespace \
  --version "$KPS_VERSION" \
  --set prometheusOperator.admissionWebhooks.enabled=false \
  --set prometheusOperator.admissionWebhooks.patch.enabled=false \
  --set prometheusOperator.tls.enabled=false \
  --set prometheusOperator.resources.requests.cpu=25m \
  --set prometheusOperator.resources.requests.memory=64Mi \
  --set prometheus.service.type=NodePort \
  --set prometheus.service.nodePort=30092 \
  --set prometheus.prometheusSpec.retention=2h \
  --set prometheus.prometheusSpec.scrapeInterval=30s \
  --set prometheus.prometheusSpec.resources.requests.cpu=100m \
  --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
  --set prometheus.prometheusSpec.resources.limits.memory=1Gi \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30091 \
  --set grafana.resources.requests.cpu=50m \
  --set grafana.resources.requests.memory=128Mi \
  --set grafana.persistence.enabled=false \
  --set alertmanager.alertmanagerSpec.resources.requests.cpu=25m \
  --set alertmanager.alertmanagerSpec.resources.requests.memory=64Mi \
  --set nodeExporter.enabled=true \
  --set kubeStateMetrics.enabled=true \
  --wait --timeout 15m

# selectorNilUsesHelmValues=false is load-bearing and easy to miss. By default
# the operator only picks up ServiceMonitors carrying the release's own Helm
# labels -- so a ServiceMonitor written by hand, or by the APISIX chart, is
# silently ignored. The targets page simply does not list it, with no error
# anywhere. Setting it false means "watch every ServiceMonitor in the cluster".
#
# --set, NOT --set-string. This was written with --set-string and it cost half
# an hour: --set-string makes the value the STRING "false", which is truthy in
# a Helm template, so the flag did the opposite of what it says. The Prometheus
# CR kept serviceMonitorSelector: {matchLabels: {release: kube-prometheus-stack}}
# and APISIX's ServiceMonitor was ignored -- 886 metrics being served, scraped
# by nobody, and no error at any layer. Check the CR, not the flag:
#
#   kubectl -n observability get prometheus -o jsonpath='{.items[0].spec.serviceMonitorSelector}'
#
# Belt and braces: the APISIX install also LABELS its ServiceMonitor with
# release=kube-prometheus-stack, so it is picked up even under the default
# selector. That is the idiomatic fix and it does not depend on this flag at
# all.

echo
echo "==> what Prometheus is actually scraping"
$K -n observability get servicemonitor --no-headers 2>/dev/null | awk '{print "    "$1}'

GRAFANA_PW="$($K -n observability get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo '<unset>')"

cat <<EOF

  Grafana      http://<node-ip>:30091      admin / $GRAFANA_PW
  Prometheus   http://<node-ip>:30092      NO PASSWORD -- see node_service_cidrs

Verify before trusting a dashboard -- an empty graph and a broken scrape look
identical:

  kubectl --context $CLUSTER -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
  # then Status -> Targets, and check nothing unexpected is DOWN
EOF
