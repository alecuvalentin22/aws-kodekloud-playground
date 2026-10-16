#!/usr/bin/env bash
# Run on the LAPTOP (not in Semaphore). Writes a kubeconfig for the playground
# cluster that works from inside the `kind` Docker network:
# https://playground-control-plane:6443 instead of 127.0.0.1:<random port>.
# Context name stays kind-playground, which is what `play` and the drills use.
#
#   playground/semaphore/kubeconfig.sh
#
# Re-run after recreating the cluster (the CA changes).
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
out="$STATE/kubeconfig-internal"
umask 077
kind get kubeconfig --name "$CLUSTER" --internal > "$out.tmp"
grep -q 'server: https://playground-control-plane:6443' "$out.tmp" \
  || die "unexpected server address in the internal kubeconfig"
mv "$out.tmp" "$out"
chmod 600 "$out"
c_ok "$out (mode 600) -- Semaphore reads it as /state/kubeconfig-internal"
