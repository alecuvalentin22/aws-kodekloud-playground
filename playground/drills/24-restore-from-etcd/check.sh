#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/homelab.sh"
# shellcheck disable=SC1091
source "$HL_STATE/24-originals" 2>/dev/null || { c_bad "no record of the originals (did play start 24 run?)"; exit 1; }
fail=0
hl_nodes_ready && c_ok "3/3 nodes Ready" || { c_bad "not all nodes Ready"; fail=1; }
hl_demo_ready && c_ok "demo-api still Ready" || { c_bad "demo-api not Ready"; fail=1; }
now_cm=$(K -n payroll get cm payout-calendar -o jsonpath='{.metadata.uid}' 2>/dev/null)
now_sec=$(K -n payroll get secret bank-api -o jsonpath='{.metadata.uid}' 2>/dev/null)
now_tok=$(K -n payroll get secret bank-api -o jsonpath='{.data.token}' 2>/dev/null | shasum -a 256 | cut -c1-16)
if [[ -z $now_cm || -z $now_sec ]]; then c_bad "payroll/payout-calendar and payroll/bank-api are not back"; exit 1; fi
if [[ $now_cm == "$cm" && $now_sec == "$secret" ]]; then
  c_ok "both objects are the ORIGINALS (same UIDs) -- restored, not re-created"
else
  c_bad "the objects exist but are NEW (different UIDs): re-created by hand, not restored"; fail=1
fi
[[ $now_tok == "$token_sha" ]] && c_ok "the Secret's value matches the original" || { c_bad "the Secret's value differs from the original"; fail=1; }
(( fail )) && exit 1
a=$(hl_answer 24)
if [[ -z $a ]]; then
  echo "PENALTY 20 No write-up in ~/platform-playground-homelab/answers/24.md -- the ticket asked what it cost."
elif grep -qE 'whole cluster|entire cluster|everything (since|after)|roll(s|ed)? back|lost|cost' <<<"$a"; then
  c_ok "write-up names the blast radius of a cluster restore (keyword check)"
else
  echo "PENALTY 15 The write-up does not say what a cluster-wide restore costs (everything after the snapshot is rolled back)."
fi
