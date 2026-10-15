#!/usr/bin/env bash
# Artifactory OSS on EKS (NodePort 30097). See ci/artifactory/artifactory.yaml
# for why it is here rather than on ECS on the playground.
#
#   ./scripts/artifactory-install.sh        # or: make artifactory
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-andrei-lab-eks}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CLUSTER}"
K="kubectl --context $CLUSTER"

$K create namespace artifactory --dry-run=client -o yaml | $K apply -f - >/dev/null
# Generated once and kept: changing the master key on an existing install makes
# everything it encrypted unreadable.
$K -n artifactory get secret artifactory-keys >/dev/null 2>&1 || \
  $K -n artifactory create secret generic artifactory-keys \
    --from-literal=master-key="$(openssl rand -hex 32)" \
    --from-literal=join-key="$(openssl rand -hex 32)" >/dev/null
$K apply -f "$HERE/ci/artifactory/artifactory.yaml" >/dev/null
echo "==> waiting for Artifactory (cold start is several minutes)"
$K -n artifactory rollout status deploy/artifactory --timeout=15m
IP="$($K get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
echo
echo "  Artifactory  http://$IP:30097   admin / password (forced change on first login)"
