#!/usr/bin/env bash
# Put back everything drill 52 changed: the job, the repo and the player's
# clone, and the agent (back to the state it had before the first static drill).
# Safe to run when drill 52 was never played.
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
ORG=billing REPO=invoice-gen JOB=invoice-gen
STATE_FILE="$STATE/drill52.state"
[[ -f $STATE_FILE ]] || exit 0

job_drop "$JOB"
repo_drop "$ORG" "$REPO"
agent_restore_baseline
rm -f "$STATE_FILE"
exit 0
