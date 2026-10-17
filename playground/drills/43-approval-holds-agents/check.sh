#!/usr/bin/env bash
# Fixed means: (1) no build is waiting for approval while holding an agent,
# (2) the approval still exists and can time out, (3) a build of the fixed
# pipeline REALLY reaches the approval with zero agent pods and then completes,
# (4) the other teams' builds run. The cap must not have been "fixed" instead.
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
ORG=fulfilment REPO=order-router JOB=order-router
JPATH="/job/$JOB/job/main"
STATE_FILE="$STATE/drill43.state"
[[ -f $STATE_FILE ]] || { c_bad "drill 43 is not set up (no $STATE_FILE); play reset, then play start 43"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"

jg() { curl -fsSg -u "admin:$JENKINS_PASSWORD" "$JENKINS_URL$1"; }
status_of() { jg "$JPATH/$1/wfapi/describe" 2>/dev/null | jq -r '.status // empty'; }
# Agent pods of one build of the job (annotation runUrl = job/order-router/job/main/<n>/), not terminating.
pods_of() {
  K -n jenkins get pods -o json 2>/dev/null | jq -r --arg u "job/$JOB/job/main/$1/" \
    '.items[] | select(.metadata.deletionTimestamp == null) | select((.metadata.annotations.runUrl // "") == $u) | .metadata.name'
}
stop_build() { jenkins_post "$JENKINS_URL$JPATH/$1/stop" >/dev/null 2>&1 || true; }
fail=0
bad() { c_bad "$1"; fail=1; }

jg "$JPATH/api/json" >/dev/null 2>&1 || { c_bad "the order-router job is gone; play reset, then play start 43"; exit 1; }

# --- 1. builds that are waiting for input AND hold an agent pod --------------------
running=$(jg "$JPATH/api/json?tree=builds[number,building]" | jq -r '.builds[] | select(.building) | .number')
holders=0
for n in $running; do
  [[ $(status_of "$n") == PAUSED_PENDING_INPUT ]] || continue
  p=$(pods_of "$n" | tr '\n' ' ')
  if [[ -n $p ]]; then
    bad "build #$n is waiting for approval and still holds agent pod(s): $p"
    holders=$((holders + 1))
  fi
done
(( holders == 0 )) && c_ok "no build is waiting for input while holding an agent pod"

# --- 2. what the Jenkinsfile on main says ----------------------------------------------
jf=$(curl -fsS "$GITEA_URL/$ORG/$REPO/raw/branch/main/Jenkinsfile") || { c_bad "cannot read the Jenkinsfile from Gitea"; exit 1; }
code=$(sed 's#//.*##' <<<"$jf")
has_input=0
grep -Eq '(^|[^[:alnum:]_.])input([[:space:]]*[({]|[[:space:]]+(message|id|ok|submitter))' <<<"$code" && has_input=1
if (( has_input )); then
  c_ok "the approval (input) is still in the pipeline"
else
  echo "PENALTY 40 You removed the approval. Compliance asked for it; fix WHERE it waits, not WHETHER it exists."
fi

# every timeout(...) in the file, in minutes; at least one, and none absurd
longest=0 found=0
while IFS= read -r line; do
  grep -Eq 'timeout[[:space:]]*\(' <<<"$line" || continue
  found=1
  t=$(sed -nE "s/.*time:[[:space:]]*([0-9]+).*/\1/p" <<<"$line")
  u=$(sed -nE "s/.*unit:[[:space:]]*['\"]([A-Za-z]+)['\"].*/\1/p" <<<"$line")
  [[ -n $t ]] || continue
  case "${u:-MINUTES}" in
    SECONDS) m=$(( t / 60 )) ;; MINUTES) m=$t ;; HOURS) m=$(( t * 60 )) ;; DAYS) m=$(( t * 1440 )) ;; *) m=$t ;;
  esac
  (( m > longest )) && longest=$m
done <<<"$code"
if (( ! found )); then
  bad "no timeout anywhere: a question nobody answers keeps the build (and the controller's bookkeeping) alive forever"
elif (( longest > 10080 )); then
  bad "the longest timeout is $longest minutes (> 7 days): that is not a timeout"
else
  c_ok "a timeout exists (longest ${longest:-unknown} min)"
fi

# --- 3. the cap was not the fix ----------------------------------------------------------
cap=$(jenkins_groovy "print jenkins.model.Jenkins.get().clouds.getByName('kubernetes').containerCapStr")
if [[ $cap =~ ^[0-9]+$ ]] && (( cap > CAP_LOW )); then
  echo "PENALTY 30 You raised the Kubernetes cloud's agent cap ($CAP_LOW -> $cap) instead of fixing the pipeline. Parked builds are still parked; you bought a few hours."
else
  c_ok "the cloud's agent cap is still $cap (platform's decision, untouched)"
fi

# --- 4. the two builds that were parked ----------------------------------------------------
for n in $BAD_BUILDS; do
  res=$(jg "$JPATH/$n/api/json?tree=result,building" 2>/dev/null | jq -r 'if .building then "RUNNING" else (.result // "?") end')
  case $res in
    SUCCESS) echo "PENALTY 15 You clicked Proceed on build #$n: a production release that the release manager had not approved went out." ;;
    RUNNING) : ;;   # already reported in step 1 if it holds a pod
  esac
done

(( fail )) && exit 1

# --- 5. run the fixed pipeline for real ----------------------------------------------------
# A build parked at the approval WITHOUT a pod can block a new build (if the
# team uses disableConcurrentBuilds). Those are harmless to cap, so clear them.
for n in $running; do
  [[ $(status_of "$n") == PAUSED_PENDING_INPUT ]] && stop_build "$n"
done

# A multibranch job builds the revision it LAST INDEXED. Re-index now and wait for
# it, or this would test the commit before the candidate's fix.
idx_start() { jg "/job/$JOB/indexing/consoleText" 2>/dev/null | grep -m1 'Starting branch indexing'; }
before=$(idx_start)
jenkins_post "$JENKINS_URL/job/$JOB/build?delay=0" >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  now=$(idx_start)
  if [[ -n $now && $now != "$before" ]] && jg "/job/$JOB/indexing/consoleText" 2>/dev/null | grep -q '^Finished:'; then break; fi
  sleep 2
done

next=$(jg "$JPATH/api/json?tree=nextBuildNumber" | jq -r .nextBuildNumber)
loc=$(curl -sS -D - -o /dev/null -b "$JAR" -u "admin:$JENKINS_PASSWORD" -H "$(jenkins_crumb)" \
  -X POST "$JENKINS_URL$JPATH/build?delay=0" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')
n=""
for _ in $(seq 1 60); do
  n=$(jg "$JPATH/api/json?tree=nextBuildNumber" 2>/dev/null | jq -r '.nextBuildNumber - 1')
  (( n >= next )) && break
  sleep 3
done
(( n >= next )) || { c_bad "the verification build did not start in 3 minutes (queue: ${loc:-?}). Is something still holding the agents?"; exit 1; }
c_ok "started verification build #$n of the fixed pipeline"

end=$(( $(date +%s) + 300 ))
reached=0
while (( $(date +%s) < end )); do
  b=$(jg "$JPATH/$n/api/json?tree=result,building" 2>/dev/null)
  if [[ $(jq -r '.building' <<<"$b" 2>/dev/null) == false ]]; then
    res=$(jq -r '.result // "?"' <<<"$b")
    if [[ $res == SUCCESS ]] && (( ! has_input )); then reached=2; break; fi
    c_bad "build #$n ended $res before reaching the approval: $JENKINS_URL$JPATH/$n/console"; exit 1
  fi
  [[ $(status_of "$n") == PAUSED_PENDING_INPUT ]] && { reached=1; break; }
  sleep 4
done
(( reached )) || { stop_build "$n"; c_bad "build #$n did not reach the approval within 5 minutes: $JENKINS_URL$JPATH/$n/console"; exit 1; }

if (( reached == 1 )); then
  # The pod of a stage that just ended is deleted a moment later; give it 40 s.
  held=""
  for _ in $(seq 1 10); do
    held=$(pods_of "$n" | tr '\n' ' ')
    [[ -z $held ]] && break
    sleep 4
  done
  if [[ -n $held ]]; then
    stop_build "$n"
    c_bad "build #$n is waiting for approval and holds agent pod(s): $held"
    exit 1
  fi
  c_ok "build #$n waits for approval holding ZERO agent pods"
  # The approval must still lead somewhere: act as the release manager.
  jenkins_post "$JENKINS_URL$JPATH/$n/input/$(jg "$JPATH/$n/wfapi/pendingInputActions" | jq -r '.[0].id')/proceedEmpty" >/dev/null 2>&1 || true
fi
end=$(( $(date +%s) + 240 ))
while (( $(date +%s) < end )); do
  res=$(jg "$JPATH/$n/api/json?tree=result,building" | jq -r 'if .building then "RUNNING" else (.result // "?") end')
  [[ $res != RUNNING ]] && break
  sleep 4
done
if [[ $res != SUCCESS ]]; then
  stop_build "$n"
  c_bad "after the approval, build #$n ended '$res': $JENKINS_URL$JPATH/$n/console"; exit 1
fi
if (( reached == 1 )); then c_ok "build #$n continued after the approval and finished SUCCESS"
else c_ok "build #$n finished SUCCESS (there is no approval step in it any more)"; fi

# --- 6. the point of the ticket: the other team's build runs ----------------------------------
assert_main_green_since "$DRILL_STARTED" || exit 1
