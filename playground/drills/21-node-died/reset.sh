#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/homelab.sh"
[[ $(hl_wsl incus list rke2-a2 -f csv -c s) == RUNNING ]] || hl_wsl incus start rke2-a2
hl_wait 600 "rke2-a2 Ready" bash -c '[[ $(kubectl get node rke2-a2 -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}") == True ]]'
K -n jenkins rollout status sts/jenkins --timeout=600s >/dev/null 2>&1 || true
rm -f "$HL_STATE/21-pvc-uids"
