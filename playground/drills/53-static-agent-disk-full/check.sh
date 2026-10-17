#!/usr/bin/env bash
# Fixed means: (1) the node is back ONLINE with Jenkins' disk checks still on and
# at least as strict as before, (2) the pipeline no longer grows the workspace:
# the check runs four exports back to back, all must pass, and the workspace
# must not have grown by more than a build's worth, (3) there is room left.
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
ORG=finance REPO=ledger-export JOB=ledger-export
STATE_FILE="$STATE/drill53.state"
[[ -f $STATE_FILE ]] || { c_bad "drill 53 is not set up (no $STATE_FILE); play reset, then play start 53"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
fail=0; bad() { c_bad "$1"; fail=1; }
jg "/job/$JOB/api/json" >/dev/null 2>&1 || { c_bad "the ledger-export job is gone; play reset, then play start 53"; exit 1; }

used_mb() { agent_ws_exec "df -P -B1M $AGENT_WS | awk 'NR==2{print \$3}'" 2>/dev/null; }
free_mb() { agent_ws_exec "df -P -B1M $AGENT_WS | awk 'NR==2{print \$4}'" 2>/dev/null; }
refresh() { jenkins_groovy "hudson.model.ComputerSet.getMonitors().each { it.triggerUpdate() }; sleep(3000); println 'ok'" >/dev/null 2>&1; }   # = Nodes -> "Refresh status"

# --- 1. thresholds: have they been loosened? -----------------------------------------------
refresh
th=$(jenkins_groovy "
import hudson.node_monitors.*
def mons = ComputerSet.getMonitors()
println([mons.find { it instanceof DiskSpaceMonitor }.ignored ? 1 : 0, mons.find { it instanceof TemporarySpaceMonitor }.ignored ? 1 : 0].join(' '))")
read -r ign_d ign_t <<<"$th"
# What Jenkins APPLIES to this node (bytes), as the node page's monitor data shows it.
md=$(jg "/computer/$AGENT_NODE/api/json?depth=2" | jq -r '.monitorData
  | [(.["hudson.node_monitors.DiskSpaceMonitor"].threshold // -1), (.["hudson.node_monitors.TemporarySpaceMonitor"].threshold // -1)] | join(" ")')
read -r t_disk t_temp <<<"$md"
loosened=0
(( t_disk >= 0 && t_disk < 16777216 )) && loosened=1      # baseline: offline below 16 MiB free
(( t_temp >= 0 && t_temp < 33554432 )) && loosened=1      # baseline: /tmp below 64 MiB free (leave slack)
(( ign_d == 1 || ign_t == 1 )) && loosened=1              # monitor switched off
if (( loosened )); then
  echo "PENALTY 25 You loosened Jenkins' disk checks (workspace threshold $(( t_disk / 1048576 )) MiB, ignored=${ign_d}/${ign_t}). The monitor was right: it takes a node out BEFORE builds die half-way. Lowering it only moves the ENOSPC into the build."
else c_ok "the disk-space checks are as strict as before"; fi

# --- 2. the node ----------------------------------------------------------------------------------
refresh
nj=$(agent_node_json)
if [[ -z $nj ]]; then bad "node $AGENT_NODE does not exist any more"; exit 1; fi
if [[ $(jq -r .offline <<<"$nj") == true ]]; then
  bad "$AGENT_NODE is still offline: $(jq -r '.offlineCauseReason // "no reason recorded"' <<<"$nj" | head -c 150)"
  echo "      workspace now: $(used_mb) MB used, $(free_mb) MB free"; exit 1
fi
c_ok "$AGENT_NODE is online ($(free_mb) MB free)"

# --- 3. four exports back to back --------------------------------------------------------------------
before=$(used_mb)
for i in 1 2 3 4; do
  build_run "$JOB" 150 || { c_bad "could not start a build"; exit 1; }
  n=$BUILD_N; res=$BUILD_RESULT
  if [[ $res != SUCCESS ]]; then
    [[ $res == RUNNING || $res == QUEUED ]] && build_abort "$JOB" "$n"
    bad "export $i of 4: build #$n ended $res: $JENKINS_URL/job/$JOB/$n/console"
    build_console "$JOB" "$n" | grep -E "No space|ENOSPC|offline|Still waiting" | head -2 | sed 's/^/      /'
    exit 1
  fi
done
after=$(used_mb)
growth=$(( after - before ))
c_ok "four exports in a row: all SUCCESS (workspace used: ${before} -> ${after} MB)"
if (( growth > 30 )); then
  echo "PENALTY 25 The pipeline still leaves its output behind: the workspace grew ${growth} MB over four exports. Space was made, the leak was not closed: it fills again."
else c_ok "the workspace did not grow: nothing is left behind by a build"; fi
refresh
nj=$(agent_node_json)
if [[ $(jq -r .offline <<<"$nj") == true ]]; then bad "after the exports the node went offline again: $(jq -r .offlineCauseReason <<<"$nj" | head -c 120)"; exit 1; fi
free=$(free_mb)
if (( free < 40 )); then bad "only ${free} MB left on the workspace volume: clean more (the deleted job's old workspace?)"; exit 1; fi
c_ok "${free} MB free of 96 after the exports"

# --- 4. the Jenkinsfile on main -----------------------------------------------------------------------
jf=$(curl -fsS "$GITEA_URL/$ORG/$REPO/raw/branch/main/Jenkinsfile" 2>/dev/null | sed 's#//.*##')
if ! grep -Eq "label[[:space:]]+['\"][^'\"]*static" <<<"$jf"; then
  echo "PENALTY 20 The export no longer asks for label 'static'. It needs the finance VPN route that only build-01 has."
fi
grep -q 'buildDiscarder' <<<"$jf" || echo "PENALTY 5 No buildDiscarder: build records and archived exports pile up on the controller's disk next."
exit 0
