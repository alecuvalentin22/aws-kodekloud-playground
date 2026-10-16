#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/homelab.sh"
# Baseline has no payroll namespace. If a restore was interrupted, make sure
# rke2-server is running normally (not in cluster-reset mode) first.
hl_wsl "incus exec rke2-s1 -- systemctl is-active --quiet rke2-server || incus exec rke2-s1 -- systemctl start rke2-server" || true
hl_wait 600 "Kubernetes API" bash -c 'kubectl get --raw /readyz'
K delete namespace payroll --ignore-not-found --wait=true >/dev/null 2>&1 || true
rm -f "$HL_STATE/24-originals"
