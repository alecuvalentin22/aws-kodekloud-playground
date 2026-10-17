#!/usr/bin/env bash
# Fixed means: (1) static-01 is ONLINE (connected) and not flagged offline,
# (2) the queued release really ran on static-01 and went green, (3) the fix is
# not "run it somewhere else": the job still wants label static and the
# controller still has no executors, (4) the next re-provision would be right too.
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
ORG=release REPO=release-signer JOB=release-signer
STATE_FILE="$STATE/drill51.state"
[[ -f $STATE_FILE ]] || { c_bad "drill 51 is not set up (no $STATE_FILE); play reset, then play start 51"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
fail=0; bad() { c_bad "$1"; fail=1; }

jg "/job/$JOB/api/json" >/dev/null 2>&1 || { c_bad "the release-signer job is gone; play reset, then play start 51"; exit 1; }

# --- 1. the node -----------------------------------------------------------------------
nj=$(agent_node_json)
if [[ -z $nj ]]; then bad "node $AGENT_NODE does not exist any more (it is a registered, permanent node; do not delete it)"
else
  if [[ $(jq -r .temporarilyOffline <<<"$nj") == true ]]; then
    bad "$AGENT_NODE is still flagged 'temporarily offline': $(jq -r '.offlineCauseReason' <<<"$nj" | head -c 120). A connected agent does not clear that."
  elif [[ $(jq -r .offline <<<"$nj") == true ]]; then
    bad "$AGENT_NODE is offline: $(jq -r '.offlineCauseReason // "no reason recorded"' <<<"$nj" | head -c 140). Is the agent connected? (docker logs $AGENT_CONTAINER)"
  else c_ok "$AGENT_NODE is online"; fi
fi
(( fail )) && exit 1

# --- 2. a release build on static-01 ------------------------------------------------------
# In a pipeline the stuck release is a RUNNING build, waiting inside `node {}` for
# an executor. It starts by itself once the node is up. If the candidate aborted
# it, run a fresh one.
running=$(jg "/job/$JOB/api/json?tree=builds[number,building]" | jq -r --argjson b "$BASE_BUILD" '[.builds[] | select(.building and .number > $b) | .number] | max // empty')
started=0
if [[ -n $running ]]; then latest=$running; else latest=$(build_start "$JOB"); started=1; fi
res=$(build_wait "$JOB" "$latest" 100)
case $res in
  SUCCESS) c_ok "release-signer #$latest: SUCCESS" ;;
  QUEUED|RUNNING) (( started )) && build_abort "$JOB" "$latest"; bad "release-signer #$latest has not run yet ($res): still waiting for an executor on label 'static'"; exit 1 ;;
  *) bad "release-signer #$latest ended $res: $JENKINS_URL/job/$JOB/$latest/console"; exit 1 ;;
esac
where=$(build_console "$JOB" "$latest" | sed -n 's/^.*Running on \([^ ]*\) in .*/\1/p' | head -1)
if [[ $where == "$AGENT_NODE" ]]; then c_ok "it ran on $where (the box with the key)"
else bad "it ran on '${where:-?}', not on $AGENT_NODE: the signing key is only on build-01"; fi
(( fail )) && exit 1

# --- 3. not fixed by moving the job -----------------------------------------------------------
jf=$(curl -fsS "$GITEA_URL/$ORG/$REPO/raw/branch/main/Jenkinsfile" 2>/dev/null | sed 's#//.*##')
if ! grep -Eq "label[[:space:]]+['\"][^'\"]*static" <<<"$jf"; then
  echo "PENALTY 30 You changed the job so it no longer asks for label 'static'. The release must be signed where the key is; that was never the thing to change."
fi
ex=$(jg "/api/json?tree=numExecutors" | jq -r .numExecutors)
if (( ex > 0 )); then
  echo "PENALTY 30 You gave the built-in node $ex executor(s). The controller runs no builds on purpose (it holds every credential), and the key is not on it."
fi
# any build since the incident that ran on the controller
for b in $(jg "/job/$JOB/api/json?tree=builds[number]" | jq -r '.builds[].number'); do
  (( b > BASE_BUILD )) || continue
  w=$(build_console "$JOB" "$b" | sed -n 's/^.*Running on \(.*\) in \/.*/\1/p' | head -1)
  [[ -n $w && $w != "$AGENT_NODE" ]] && { echo "PENALTY 20 Build #$b of the release ran on '$w': a release signed on the wrong machine."; break; }
done

# --- 4. the next re-provision --------------------------------------------------------------------
want=$(jenkins_groovy "print jenkins.model.Jenkins.get().getComputer('$AGENT_NODE').getJnlpMac()")
have=$(grep '^JENKINS_SECRET=' "$STATE/static-agent/agent.env" 2>/dev/null | cut -d= -f2-)
if [[ $have != "$want" ]]; then
  echo "PENALTY 5 The provisioning file (static-agent/agent.env) still holds the old secret: the next re-image brings the outage back. Fix the source, not only the running container."
else c_ok "the saved provisioning file now holds the current secret too"; fi
unset want have
exit 0
