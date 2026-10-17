#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
BR=drill45-probe
JOB="/job/demo-api/job/$BR"
repo=$(repo_url payments/demo-api)
scratch="$STATE/scratch/check45"
cleanup() { git push -q "$repo" --delete "$BR" >/dev/null 2>&1 || true; rm -rf "$scratch"; }
trap cleanup EXIT

# 0. One build at a time (the Docker VM is small, and a build that is already
#    running would be mistaken for the one this check is waiting for).
busy=$(jenkins_get "/job/demo-api/api/json?tree=jobs%5Bname,lastBuild%5Bbuilding%5D%5D" 2>/dev/null \
  | jq -r '[.jobs[] | select(.lastBuild.building == true) | .name] | join(",")' 2>/dev/null)
queued=$(jenkins_get /queue/api/json 2>/dev/null | jq -r '.items | length' 2>/dev/null)
if [[ -n $busy || ${queued:-0} != 0 ]]; then
  c_warn "Jenkins is still busy (building: ${busy:-none}, queued: ${queued:-0}) -- check again when it is idle"; exit 1
fi

# 1. The real test, the one Sam runs every time: push, and do NOT touch Jenkins.
c_dim "  pushing a harmless commit to a new branch ($BR) and waiting for Jenkins to notice by itself"
before=$(jenkins_get "$JOB/api/json?tree=lastBuild%5Bnumber%5D" 2>/dev/null | jq -r '.lastBuild.number // 0' 2>/dev/null)
before=${before:-0}
rm -rf "$scratch"
git clone -q "$repo" "$scratch" 2>/dev/null || { c_bad "could not clone payments/demo-api for the probe"; exit 1; }
git -C "$scratch" checkout -q -b "$BR"
echo "probe $(date +%s)" > "$scratch/drill45-probe.txt"
git -C "$scratch" add -A
git -C "$scratch" -c user.name="Sam (probe)" -c user.email=probe@playground.local \
  commit -q -m "drill 45 probe: a harmless commit that should start a build"
git -C "$scratch" push -q origin "$BR" 2>/dev/null || { c_bad "could not push the probe branch"; exit 1; }

# The folder is scanned every minute, so a working trigger needs up to ~1 min
# plus indexing. Give it 150 s; never call a scan from here.
t0=$(date +%s); n=0; b='{}'
while (( $(date +%s) - t0 < 150 )); do
  b=$(jenkins_get "$JOB/lastBuild/api/json?tree=number,actions%5Bcauses%5B_class%5D%5D" 2>/dev/null || echo '{}')
  n=$(jq -r '.number // 0' <<<"$b" 2>/dev/null); n=${n:-0}
  (( n > before )) && break
  sleep 5
done
if (( n <= before )); then
  c_bad "no build started for the pushed commit within 150 s -- Jenkins looked and did nothing"
  jenkins_get /job/demo-api/indexing/consoleText 2>/dev/null | grep -E 'Did not schedule|Scheduled build|Changes detected' | tail -3 | sed 's/^/      scan log: /'
  exit 1
fi
causes=$(jq -r '[.actions[]? | .causes[]? | ._class] | join(" ")' <<<"$b" 2>/dev/null)
stop_probe() { jenkins_post "$JENKINS_URL$JOB/$n/stop" >/dev/null 2>&1 || true; }
if grep -q 'UserIdCause' <<<"$causes"; then
  stop_probe; c_bad "the build on $BR was started by a person (UserIdCause), not by the push"; exit 1
fi
c_ok "build #$n on $BR started by itself (${causes##*.})"
stop_probe   # it proved the point; do not make the VM build it to the end

# 2. Penalties: a "fix" that makes the symptom go away and costs more at work.
jf=$(curl -fsS "$GITEA_URL/payments/demo-api/raw/branch/main/Jenkinsfile" 2>/dev/null || true)
lib=$(curl -fsS "$GITEA_URL/platform/platform-lib/raw/branch/main/vars/standardPipeline.groovy" 2>/dev/null || true)
if grep -Eq 'pollSCM|cron *\(|triggers *\{' <<<"$jf"$'\n'"$lib"; then
  echo "PENALTY 20 You added a second trigger (pollSCM/cron) to pipeline code instead of fixing why the one that exists was told to stay quiet. Every repo that copies it polls Gitea on its own; the next person debugging sees two triggers."
fi
