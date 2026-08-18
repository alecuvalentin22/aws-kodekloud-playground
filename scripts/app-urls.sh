#!/usr/bin/env bash
# Where the demo apps are reachable. Node public IPs change on replacement, so
# this asks the cluster rather than hardcoding anything.
set -uo pipefail
IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
[[ -z "$IP" ]] && { echo "  no node ExternalIP -- is the cluster up?"; exit 0; }
printf "  Argo CD app  http://%s:30081\n" "$IP"
printf "  Flux app     http://%s:30082\n" "$IP"
echo
echo "  Both serve podinfo. The banner tells you which controller deployed it."
