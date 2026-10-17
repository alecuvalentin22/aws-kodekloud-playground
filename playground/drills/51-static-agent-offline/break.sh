#!/usr/bin/env bash
# The release team's signing job is pinned to label `static`. It worked last
# month (build #1 here runs green on static-01). Over the weekend build-01 was
# re-imaged and "put back from the saved provisioning file", which still holds
# an OLD node secret, and the node was marked offline in Jenkins and left so.
#
# Two separate reasons the node is offline:
#   1. the agent container presents a stale secret: the controller refuses it
#      ("incorrect secret"), the agent loops on "Handshake error"
#   2. the node is flagged "temporarily offline" (Jordan's note), which a
#      connected agent does not clear
# Then a release build is queued. Everything is undone by reset.sh.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
ORG=release REPO=release-signer JOB=release-signer
STATE_FILE="$STATE/drill51.state"

bash "$(dirname "$0")/reset.sh"        # a clean slate, whatever a failed earlier run left
agent_for_drill

# --- the team's repo, the job, the player's clone -----------------------------------
repo_seed "$ORG" "$REPO" "$(dirname "$0")/repo" "release-signer: sign the monthly bundle on build-01" "Ines (release eng)"
repo_clone_for_player "$ORG" "$REPO"
job_scm "$JOB" "$ORG/$REPO" "Signs the monthly release bundle on build-01 (label static). Drill 51; removed by play reset."

# --- last month: it worked ------------------------------------------------------------
n=$(build_start "$JOB")
[[ $(build_wait "$JOB" "$n" 150) == SUCCESS ]] || die "the baseline release-signer build did not go green"
build_console "$JOB" "$n" | grep -q "Running on $AGENT_NODE" || die "baseline build did not run on $AGENT_NODE"
printf 'JOB=%s\nBASE_BUILD=%s\n' "$JOB" "$n" > "$STATE_FILE"

# --- the weekend: re-imaged from the saved file with the old secret --------------------
envf="$STATE/static-agent/agent.env"
stale=$(openssl rand -hex 32)
sed "s/^JENKINS_SECRET=.*/JENKINS_SECRET=$stale/" "$envf" > "$envf.new" && chmod 600 "$envf.new" && mv "$envf.new" "$envf"
unset stale
bash "$SA" recreate >/dev/null
# the controller notices the old connection is gone; the new one is refused.
for _ in $(seq 1 30); do
  [[ $(jq -r .offline <<<"$(agent_node_json)") == true ]] && break; sleep 2
done
# Jordan's flag, set while "working on" the box
jenkins_groovy "
def c = jenkins.model.Jenkins.get().getComputer('$AGENT_NODE')
c.setTemporarilyOffline(true, new hudson.slaves.OfflineCause.ByCLI('Jordan: build-01 disk swap, re-enable Monday'))
println 'flagged'" | grep -q flagged

# --- Monday: the release is requested -----------------------------------------------------
build_start "$JOB" >/dev/null
sleep 8
