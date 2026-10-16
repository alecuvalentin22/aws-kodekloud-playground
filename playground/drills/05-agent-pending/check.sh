#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
pending=$(K -n jenkins get pods --field-selector=status.phase=Pending -o name 2>/dev/null | wc -l | tr -d ' ')
(( pending == 0 )) || { c_bad "$pending agent pod(s) still Pending in namespace jenkins"; exit 1; }
c_ok "no Pending agent pods"
assert_main_green_since "$DRILL_STARTED" || exit 1
q=$(jenkins_get /queue/api/json | jq '.items | length')
(( q == 0 )) && c_ok "queue is empty" || c_warn "$q item(s) still queued"
