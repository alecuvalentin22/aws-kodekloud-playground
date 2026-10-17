#!/usr/bin/env bash
# Put back everything drill 53 changed: the job, the repo and the player's clone,
# the agent (back to the state it had before the first static drill; a fresh
# container also means an empty workspace and the baseline disk thresholds).
# Safe to run when drill 53 was never played.
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
ORG=finance REPO=ledger-export JOB=ledger-export
STATE_FILE="$STATE/drill53.state"
[[ -f $STATE_FILE ]] || exit 0

job_drop "$JOB"
repo_drop "$ORG" "$REPO"
agent_restore_baseline
rm -f "$STATE_FILE"
exit 0
