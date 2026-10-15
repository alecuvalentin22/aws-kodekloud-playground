#!/usr/bin/env bash
# Backstage with its catalog read from this repository's catalog-info.yaml.
#
#   ./scripts/backstage-install.sh        # or: make backstage
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-andrei-lab-eks}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CLUSTER}"
# shellcheck disable=SC1091
source "$HERE/versions.env"
K="kubectl --context $CLUSTER"

# The browser is sent to backend.baseUrl for every API call, so it has to be an
# address the VIEWER can reach -- a node's public IP, not a cluster DNS name.
IP="$($K get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
URL="http://$IP:30096"

helm repo add backstage https://backstage.github.io/charts >/dev/null 2>&1 || true
helm repo update backstage >/dev/null
helm upgrade --install backstage backstage/backstage \
  --kube-context "$CLUSTER" --namespace backstage --create-namespace \
  --version "$BACKSTAGE_CHART" \
  -f "$HERE/ci/backstage/values.yaml" \
  --set-string backstage.image.tag="$BACKSTAGE_IMAGE" \
  --set-string backstage.appConfig.app.baseUrl="$URL" \
  --set-string backstage.appConfig.backend.baseUrl="$URL" \
  --set-string backstage.appConfig.backend.cors.origin="$URL" \
  --wait --timeout 10m

echo
echo "  Backstage   $URL     (sign in as guest)"
echo "  Catalog source: catalog-info.yaml at the repo root, on main."
echo "  If the catalog is empty: kubectl -n backstage logs deploy/backstage | grep -i catalog"
