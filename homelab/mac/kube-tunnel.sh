#!/usr/bin/env bash
# Reach the home-lab RKE2 API from the Mac. The cluster lives on the Incus
# bridge inside WSL (10.77.0.0/24), which nothing outside the PC can route to,
# so forward localhost:6443 through the same SSH chain Ansible uses.
#
#   homelab/mac/kube-tunnel.sh          # leave it running
#   export KUBECONFIG=$PWD/homelab/generated/rke2.kubeconfig
#   kubectl get nodes
set -euo pipefail
ALIAS="${HOMELAB_SSH:-homelab-1}-wsl"
SERVER="${RKE2_SERVER_IP:-10.77.0.31}"
PORT="${RKE2_LOCAL_PORT:-6443}"
echo "localhost:$PORT -> $SERVER:6443 via $ALIAS  (Ctrl-C to stop)"
exec ssh -N -o ExitOnForwardFailure=yes -L "127.0.0.1:$PORT:$SERVER:6443" "$ALIAS"
