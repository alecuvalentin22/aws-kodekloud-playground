#!/usr/bin/env bash
# Delete the local playground: kind cluster and registry. Keeps creds, scores
# and your journal. `--all` also deletes those and ~/platform-playground.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
kind delete cluster --name "$CLUSTER" 2>/dev/null || true
docker rm -f kind-registry >/dev/null 2>&1 || true
rm -f "$STATE/current.env"
c_ok "cluster and registry deleted"
if [[ ${1:-} == --all ]]; then
  read -r -p "Also delete $STATE and $WORK (scores, journal, clones)? [y/N] " a
  [[ $a == y ]] && rm -rf "$STATE" "$WORK" && c_ok "deleted"
fi
