#!/usr/bin/env bash
# Datadog Agent on EKS. Needs a Datadog API key:
#
#   DD_API_KEY=xxxxxxxx ./scripts/datadog-install.sh        # or: make datadog
#
# A 14-day trial at datadoghq.com gives one. Without it this script refuses
# rather than installing an agent that crash-loops on authentication.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-andrei-lab-eks}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CLUSTER}"
# shellcheck disable=SC1091
source "$HERE/versions.env"

[[ -n "${DD_API_KEY:-}" ]] || {
  echo "DD_API_KEY is not set. Get one from a Datadog trial, then:" >&2
  echo "  DD_API_KEY=... $0" >&2
  echo "No key: use the cluster's Prometheus/Grafana (make observability) instead." >&2
  exit 1; }

kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# From the environment straight into a Secret -- never onto disk, never into git.
kubectl -n datadog create secret generic datadog-secret \
  --from-literal=api-key="$DD_API_KEY" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
helm repo update datadog >/dev/null
helm upgrade --install datadog datadog/datadog --namespace datadog \
  --version "$DATADOG_CHART" -f "$HERE/ci/datadog/values.yaml" --wait --timeout 10m

echo
echo "Verify from the agent's own view, not the UI -- the UI lags by minutes:"
echo "  kubectl -n datadog exec ds/datadog -c agent -- agent status | grep -A3 'API Keys'"
