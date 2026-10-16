#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/homelab.sh"
fail=0
st=$(K get node rke2-a2 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
[[ $st == True ]] && c_ok "rke2-a2 is Ready again" || { c_bad "rke2-a2 is not Ready ($st)"; fail=1; }
for w in jenkins/sts/jenkins registry/deploy/registry; do
  ns=${w%%/*}; rest=${w#*/}
  if K -n "$ns" rollout status "$rest" --timeout=5s >/dev/null 2>&1; then c_ok "$ns ${rest#*/} is up"; else c_bad "$ns ${rest#*/} is not up yet"; fail=1; fi
done
(( fail )) && exit 1
# Same volumes as before the incident?
lost=""
while IFS== read -r name uid; do
  now=$(K -n "${name%%/*}" get pvc "${name#*/}" -o jsonpath='{.metadata.uid}' 2>/dev/null)
  [[ -n $now && $now != "$uid" ]] && lost="$lost ${name}"
done < "$HL_STATE/21-pvc-uids"
if [[ -n $lost ]]; then
  echo "PENALTY 40 A PVC was deleted and recreated (${lost# }): the pod came back on an EMPTY volume -- that data is gone."
else
  c_ok "every PVC is the original one (no data thrown away)"
fi
a=$(hl_answer 21)
if [[ -z $a ]]; then
  echo "PENALTY 20 No write-up in ~/platform-playground-homelab/answers/21.md -- the ticket asked why."
elif grep -qE 'local-path|local volume|node affinity|nodeaffinity|pinned|tied to (the|a) node' <<<"$a"; then
  c_ok "write-up explains the node-local volumes (keyword check)"
else
  echo "PENALTY 15 The write-up does not say WHY these three could not move (their volumes are node-local)."
fi
