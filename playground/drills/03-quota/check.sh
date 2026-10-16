#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
assert_main_green_since "$DRILL_STARTED" || exit 1
if ! K -n demo-ci get resourcequota cost-guardrails >/dev/null 2>&1; then
  c_warn "the FinOps quota is gone"
  echo "PENALTY 30 You deleted another team's policy to unblock yourself. It works -- and it is the answer that fails the interview."
else
  c_ok "the FinOps quota is still in place: $(K -n demo-ci get resourcequota cost-guardrails -o jsonpath='{.spec.hard}')"
fi
