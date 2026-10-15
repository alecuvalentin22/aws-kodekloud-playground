#!/usr/bin/env bash
# Where the demo apps are reachable. Node public IPs change on replacement, so
# this asks the cluster rather than hardcoding anything.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-andrei-lab-eks}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CLUSTER}"
IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
[[ -z "$IP" ]] && { echo "  no node ExternalIP -- is the cluster up?"; exit 0; }

has() { kubectl get ns "$1" >/dev/null 2>&1; }
if has argocd || has flux-system; then
  printf "  Argo CD app  http://%s:30081\n" "$IP"
  printf "  Flux app     http://%s:30082\n" "$IP"
  echo "  (both serve podinfo; the banner says which controller deployed it)"
fi
if has jenkins; then
  printf "  Jenkins      http://%s:30094   admin / %s\n" "$IP" \
    "$(kubectl -n jenkins get secret jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)"
  printf "  demo-api     http://%s:30095   (deployed by the Jenkins main build)\n" "$IP"
fi
has backstage && printf "  Backstage    http://%s:30096   (sign in as guest)\n" "$IP"
if has artifactory; then
  printf "  Artifactory  http://%s:30097   admin / password (forced change)\n" "$IP"
else
  # On the playground Artifactory lives on GCP (docs/kodekloud-limits.md).
  GCP="$("$HERE/scripts/gcp-urls.sh" 2>/dev/null | sed -n 's/^Artifactory: *//p')"
  printf "  Artifactory  %s\n" "${GCP:-not running (terraform/gcp-artifactory)}"
fi
