#!/usr/bin/env bash
# Reset for the homelab tier: run the drill's own reset.sh, then wait for the
# lab to be drill-ready again. Called by `play reset` with the drill id.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/homelab.sh"
id=${1:?usage: reset-homelab.sh <drill id>}
d=$(find "$PG_ROOT/drills" -maxdepth 1 -type d -name "$id-*" | head -1)
[[ -n $d ]] || { c_bad "no drill $id"; exit 1; }
c_hdr "Resetting homelab drill $id"
if [[ -x $d/reset.sh || -f $d/reset.sh ]]; then bash "$d/reset.sh" || { c_bad "reset.sh failed"; exit 1; }; fi
hl_wait 600 "3 nodes Ready" hl_nodes_ready || exit 1
hl_wait 600 "demo-api Ready" hl_demo_ready || exit 1
rm -f "$HL_ANSWERS/$id.md"
c_ok "baseline: 3 nodes Ready, demo-api Ready"
