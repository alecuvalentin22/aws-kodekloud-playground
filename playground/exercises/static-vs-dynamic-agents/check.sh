#!/usr/bin/env bash
# Did you really run the same pipeline on both kinds of agent? Reads Jenkins'
# own records (the consoles of the last 8 builds of each job) and checks:
#   sva-static   >= 2 green builds on static-01, one of which FOUND the file the
#                previous build left (the workspace persisted)
#   sva-dynamic  >= 2 green builds on a pod agent (not static-01), none of which
#                found anything left behind
#   sva-snoop    ran green on static-01 and READ the deploy token another job left
# and prints the cold-start numbers you measured. Your notes file is optional.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/common.sh"; load_creds
NOTES="$WORK/journal/static-vs-dynamic.md"
fail=0; bad() { c_bad "$1"; fail=1; }
jg() { curl -fsSg -u "admin:$JENKINS_PASSWORD" "$JENKINS_URL$1"; }

# --- the agent ---------------------------------------------------------------------------------
nj=$(jg "/computer/static-01/api/json?tree=offline,offlineCauseReason" 2>/dev/null || true)
if [[ -z $nj ]]; then bad "no node static-01: ./lab.sh seed"
elif [[ $(jq -r .offline <<<"$nj") == true ]]; then bad "static-01 is offline: $(jq -r '.offlineCauseReason // "?"' <<<"$nj" | head -c 100) (playground/setup/static-agent.sh up)"
else c_ok "static-01 is online"; fi

# scan JOB -> lines "number node marker cold" for each green build among the last 8, oldest first
scan() {
  local job=$1 n con node marker cold
  for n in $(jg "/job/$job/api/json?tree=builds[number,result]" 2>/dev/null | jq -r '[.builds[:8][] | select(.result == "SUCCESS") | .number] | reverse | .[]'); do
    con=$(jg "/job/$job/$n/consoleText" 2>/dev/null)
    node=$(sed -n 's/^.*Running on \([^ ]*\) in .*/\1/p' <<<"$con" | head -1)
    marker=$(sed -n 's/^.*MARKER=\([a-z]*\).*/\1/p' <<<"$con" | head -1)
    cold=$(sed -n 's/^.*COLD_START_MS=\([0-9]*\).*/\1/p' <<<"$con" | head -1)
    echo "$n ${node:-?} ${marker:-?} ${cold:-0}"
  done
}
median() { sort -n | awk '{a[NR]=$1} END{ if (NR) print a[int((NR+1)/2)]; else print "-" }'; }

# --- sva-static ----------------------------------------------------------------------------------------
if ! jg "/job/sva-static/api/json" >/dev/null 2>&1; then bad "no job sva-static: ./lab.sh seed"
else
  s=$(scan sva-static)
  on_static=$(awk '$2 == "static-01"' <<<"$s" | wc -l | tr -d ' ')
  found=$(awk '$2 == "static-01" && $3 == "found"' <<<"$s" | wc -l | tr -d ' ')
  if (( on_static < 2 )); then bad "sva-static: $on_static green build(s) on static-01 (need 2: run it twice)"
  else c_ok "sva-static: $on_static green builds on static-01"; fi
  if (( found >= 1 )); then c_ok "sva-static: a later build FOUND the file the earlier one left (MARKER=found): the workspace persisted"
  elif (( on_static >= 2 )); then bad "sva-static: no build saw a leftover (MARKER=found). Run it again without wiping the workspace."; fi
  static_cold=$(awk '$2 == "static-01" && $4 > 0 {print $4}' <<<"$s" | median)
fi

# --- sva-dynamic -------------------------------------------------------------------------------------------
if ! jg "/job/sva-dynamic/api/json" >/dev/null 2>&1; then bad "no job sva-dynamic: ./lab.sh seed"
else
  d=$(scan sva-dynamic)
  on_pod=$(awk '$2 ~ /^sva-dynamic/' <<<"$d" | wc -l | tr -d ' ')
  leftover=$(awk '$2 ~ /^sva-dynamic/ && $3 == "found"' <<<"$d" | wc -l | tr -d ' ')
  if (( on_pod < 2 )); then bad "sva-dynamic: $on_pod green build(s) on a pod agent (need 2: run it twice)"
  else c_ok "sva-dynamic: $on_pod green builds, each on its own pod ($(awk '$2 ~ /^sva-dynamic/ {print $2}' <<<"$d" | tail -2 | tr '\n' ' '))"; fi
  if (( leftover > 0 )); then bad "sva-dynamic: $leftover build(s) FOUND a leftover file. Did you change the job to use a persistent volume or the static label?"
  elif (( on_pod >= 2 )); then c_ok "sva-dynamic: no build found anything left behind: every pod starts empty"; fi
  dyn_cold=$(awk '$2 ~ /^sva-dynamic/ && $4 > 0 {print $4}' <<<"$d" | median)
fi

# --- sva-snoop: the security half --------------------------------------------------------------------------------
if ! jg "/job/sva-snoop/api/json" >/dev/null 2>&1; then bad "no job sva-snoop: ./lab.sh seed"
else
  n=$(jg "/job/sva-snoop/api/json?tree=builds[number,result]" | jq -r '[.builds[] | select(.result == "SUCCESS") | .number] | first // empty')
  if [[ -z $n ]]; then bad "sva-snoop has no green build yet: run it once AFTER sva-static has run"
  else
    con=$(jg "/job/sva-snoop/$n/consoleText")
    if grep -q "FAKE-DEPLOY-TOKEN" <<<"$con" && grep -q "Running on static-01" <<<"$con"; then
      c_ok "sva-snoop #$n (a different job) read the token sva-static left on static-01"
    else bad "sva-snoop #$n did not see the token sva-static leaves behind: run sva-static, then sva-snoop (same node)"; fi
  fi
fi

# --- numbers ---------------------------------------------------------------------------------------------------------
echo
echo "  cold start (build start -> first step on the agent), median of your green builds:"
echo "    static  ${static_cold:--} ms        dynamic  ${dyn_cold:--} ms"
if [[ ${static_cold:-} =~ ^[0-9]+$ && ${dyn_cold:-} =~ ^[0-9]+$ ]]; then
  if (( dyn_cold > static_cold )); then c_ok "the pod paid its start-up: ${dyn_cold} ms vs ${static_cold} ms"
  else c_warn "the pod was not slower here (${dyn_cold} vs ${static_cold} ms). The image was cached on the node; try again after a new image tag, and say why it varies."; fi
fi
if [[ -f $NOTES ]] && (( $(wc -w < "$NOTES") >= 100 )); then c_ok "your notes: $NOTES ($(wc -w < "$NOTES" | tr -d ' ') words)"
else c_warn "optional: write your answers to the README's questions in $NOTES (100+ words) and say them out loud"; fi

(( fail )) && { echo; c_warn "Not there yet; fix the red lines and re-run ./check.sh"; exit 1; }
echo; c_ok "Exercise done. Now the interview questions at the bottom of the README, out loud."
