#!/usr/bin/env bash
# Fixed means: the pipeline does not depend on what a previous build (or a crash
# or an abort) left in the workspace. The check proves it by BEHAVIOUR: it plants
# leftovers on the agent (a stale vendor/, last release's dist/ with the removed
# template, a canary file), runs two builds back to back, and requires that
# both are green, fetch money-lib 2.0.0 fresh, ship NO legacy.tmpl, and leave
# the canary gone. The job must still run on the static agent.
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
ORG=billing REPO=invoice-gen JOB=invoice-gen
STATE_FILE="$STATE/drill52.state"
[[ -f $STATE_FILE ]] || { c_bad "drill 52 is not set up (no $STATE_FILE); play reset, then play start 52"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
WS="$AGENT_WS/workspace/$JOB"
fail=0; bad() { c_bad "$1"; fail=1; }

jg "/job/$JOB/api/json" >/dev/null 2>&1 || { c_bad "the invoice-gen job is gone; play reset, then play start 52"; exit 1; }
nj=$(agent_node_json)
if [[ -z $nj || $(jq -r .offline <<<"$nj") == true ]]; then
  c_bad "static-01 is offline (docker logs $AGENT_CONTAINER; playground/setup/static-agent.sh status)"; exit 1
fi

# --- 1. still on the static agent, still reading the same repo ---------------------------
jf=$(curl -fsS "$GITEA_URL/$ORG/$REPO/raw/branch/main/Jenkinsfile" 2>/dev/null | sed 's#//.*##')
[[ -n $jf ]] || { c_bad "cannot read the Jenkinsfile from Gitea"; exit 1; }
if grep -Eq "label[[:space:]]+['\"][^'\"]*static" <<<"$jf"; then c_ok "the job still asks for label 'static'"
else echo "PENALTY 20 The job no longer runs on the static agent. A pod hides this bug (it always starts empty) but the renderer licence is tied to build-01: that is a workaround, not the fix."; fi

# --- 2. two builds back to back, each on top of planted leftovers -------------------------
plant() {
  agent_ws_exec "mkdir -p $WS/vendor/money-lib $WS/dist/templates \
    && echo 1.4.0 > $WS/vendor/money-lib/VERSION \
    && echo 'Report-To: http://billing-int.corp.example:8080/legacy-reports' > $WS/dist/templates/legacy.tmpl \
    && echo canary > $WS/leftover-canary"
}
verify_round() {   # verify_round LABEL
  local label=$1 n res con rel
  plant || { c_bad "could not plant the leftovers on the agent"; return 1; }
  build_run "$JOB" 150 || { c_bad "could not start a build"; return 1; }
  n=$BUILD_N; res=$BUILD_RESULT
  con=$(build_console "$JOB" "$n")
  if [[ $res != SUCCESS ]]; then
    [[ $res == RUNNING || $res == QUEUED ]] && build_abort "$JOB" "$n"
    bad "$label: build #$n ended $res: $JENKINS_URL/job/$JOB/$n/console"
    grep -E "money-lib|FAIL|cache hit" <<<"$con" | head -4 | sed 's/^/      /'
    return 1
  fi
  c_ok "$label: build #$n SUCCESS, with a stale vendor/, dist/ and canary waiting for it"
  if ! grep -q "Running on $AGENT_NODE" <<<"$con"; then bad "$label: build #$n did not run on $AGENT_NODE"; return 1; fi
  if grep -q "cache hit" <<<"$con" || ! grep -q "fetching money-lib 2.0.0" <<<"$con"; then
    bad "$label: build #$n did not fetch money-lib 2.0.0 fresh: it trusted what was in the workspace"; return 1
  fi
  rel=$(sed -n '/^.*release.tgz contains:/,$p' <<<"$con")
  if grep -q "legacy.tmpl" <<<"$rel"; then bad "$label: build #$n SHIPPED templates/legacy.tmpl (the removed template is in the release)"; return 1; fi
  if ! grep -q "invoice.tmpl" <<<"$rel"; then bad "$label: build #$n has no invoice.tmpl in its release listing"; return 1; fi
  if agent_ws_exec "test -e $WS/leftover-canary"; then
    bad "$label: the workspace still holds the canary file from before the build: nothing wipes it"; return 1
  fi
  c_ok "$label: fresh money-lib 2.0.0, no legacy.tmpl in the release, canary gone"
}
verify_round "build A" && verify_round "build B (right after A)"
(( fail )) && exit 1

exit 0
