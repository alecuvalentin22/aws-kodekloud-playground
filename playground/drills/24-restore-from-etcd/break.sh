#!/usr/bin/env bash
# Baseline objects that exist ONLY in the cluster (not in git, not managed by
# Argo CD), an on-demand etcd snapshot, then the "cleanup script".
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/homelab.sh"
K create namespace payroll --dry-run=client -o yaml | K apply -f - >/dev/null
K -n payroll create configmap payout-calendar --from-literal=next-run="$(date -u -v+3d +%F 2>/dev/null || date -u -d '+3 days' +%F)" \
  --from-literal=cutoff=17:00 --dry-run=client -o yaml | K apply -f - >/dev/null
K -n payroll create secret generic bank-api --from-literal=token="drill24-$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | K apply -f - >/dev/null
# Identity of the originals: a restore from etcd brings back these exact UIDs;
# re-creating the objects by hand cannot.
{ echo "cm=$(K -n payroll get cm payout-calendar -o jsonpath='{.metadata.uid}')"
  echo "secret=$(K -n payroll get secret bank-api -o jsonpath='{.metadata.uid}')"
  echo "token_sha=$(K -n payroll get secret bank-api -o jsonpath='{.data.token}' | shasum -a 256 | cut -c1-16)"
} > "$HL_STATE/24-originals"
sleep 3
hl_wsl "incus exec rke2-s1 -- rke2 etcd-snapshot save --name drill24-before-cleanup" 2>&1 | grep -i 'saved' >/dev/null
K delete namespace payroll --wait=true >/dev/null
