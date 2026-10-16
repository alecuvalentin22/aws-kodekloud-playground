#!/usr/bin/env bash
# Is the home lab ready for a drill? One clear line when it is not.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/homelab.sh"
fail() { c_bad "$*"; exit 1; }

[[ -r $KUBECONFIG ]] || fail "No $KUBECONFIG -- run homelab/mac/lan-kube-api.sh first."
K get --raw /readyz >/dev/null 2>&1 \
  || fail "Kubernetes API at https://$HL_IP:6443 not answering (PC off, or just booted: give it ~2 min)."
hl_nodes_ready || fail "Not all 3 nodes Ready: $(K get nodes --no-headers 2>/dev/null | awk '{printf "%s=%s ", $1, $2}')"

# After a reboot the platform needs ~12 min, Artifactory ~21 (homelab/README.md).
bad=$(K -n argocd get applications --no-headers 2>/dev/null | awk '$3 != "Healthy" {print $1"("$3")"}' | tr '\n' ' ')
if [[ -n $bad ]]; then
  if [[ $bad == *artifactory* && $(wc -w <<<"$bad") -le 2 ]]; then
    c_warn "Artifactory still starting ($bad) -- fine for every drill except ones that use it."
  else
    fail "Argo CD apps not Healthy yet: $bad (after a reboot allow ~12 min)."
  fi
fi
hl_demo_ready || fail "demo-api in demo-ci is not fully Ready -- run a Jenkins main build first (http://jenkins.$HL_IP.nip.io)."
c_ok "home lab ready: 3 nodes, platform Healthy, demo-api Ready"
