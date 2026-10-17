#!/usr/bin/env bash
# The finance team's nightly ledger-export runs on the static agent, whose
# workspace volume is a 96 MB tmpfs (a bounded stand-in for a small disk; it can
# never touch the host's disk). Two things fill it, as in real life:
#   - a deleted job's workspace that nothing cleans from a static agent (30 MB)
#   - ledger-export itself, 28 MB per build, never deleted
# Builds 1 and 2 pass, build 3 dies of "No space left on device", Jenkins'
# disk-space monitor takes the node offline, and the retry (build 4) waits for it.
#
# Everything this creates is removed by reset.sh (job, repo, clone, agent).
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
ORG=finance REPO=ledger-export JOB=ledger-export
STATE_FILE="$STATE/drill53.state"

bash "$(dirname "$0")/reset.sh"        # a clean slate, whatever a failed earlier run left
agent_for_drill

repo_seed "$ORG" "$REPO" "$(dirname "$0")/repo" "ledger-export: nightly CSV export" "Marta (finance)"
repo_clone_for_player "$ORG" "$REPO"
job_scm "$JOB" "$ORG/$REPO" "Nightly ledger export on build-01 (label static). Drill 53; removed by play reset."
printf 'JOB=%s\n' "$JOB" > "$STATE_FILE"

# --- the leftover from a job deleted months ago --------------------------------------------
agent_ws_exec "set -e; d=$AGENT_WS/workspace/payroll-batch
  mkdir -p \$d/artifacts $AGENT_WS/workspace/payroll-batch@tmp
  head -c 30M /dev/zero | tr '\\0' 'p' > \$d/artifacts/payroll-2026-08.csv
  touch -d '60 days ago' \$d/artifacts/payroll-2026-08.csv \$d/artifacts \$d"

# --- the nights that passed ------------------------------------------------------------------
for _ in 1 2; do
  build_run "$JOB" 150; n=$BUILD_N
  [[ $BUILD_RESULT == SUCCESS ]] || die "an early ledger-export build failed: $JENKINS_URL/job/$JOB/$n/console"
done
# --- the night it did not fit ------------------------------------------------------------------
build_run "$JOB" 150; n=$BUILD_N; res=$BUILD_RESULT
[[ $res == FAILURE ]] || die "build $n should have run out of space (got $res)"
build_console "$JOB" "$n" | grep -q "No space left on device" || die "build $n failed, but not with ENOSPC"
printf 'BAD_BUILD=%s\n' "$n" >> "$STATE_FILE"

# --- Jenkins notices: the disk-space monitor takes the node offline --------------------------------
jenkins_groovy "hudson.model.ComputerSet.getMonitors().find { it instanceof hudson.node_monitors.DiskSpaceMonitor }.triggerUpdate(); sleep(3000); println 'triggered'" >/dev/null
for _ in $(seq 1 20); do
  [[ $(jq -r .offline <<<"$(agent_node_json)") == true ]] && break; sleep 2
done
[[ $(jq -r .offline <<<"$(agent_node_json)") == true ]] || die "the disk-space monitor did not take $AGENT_NODE offline"

# --- Marta re-runs it ---------------------------------------------------------------------------------
build_start "$JOB" >/dev/null
sleep 5
