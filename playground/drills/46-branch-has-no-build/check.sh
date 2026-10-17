#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
snap="$STATE/drill46.items"
[[ -f $snap ]] || { c_bad "no item snapshot from break.sh (drill not started properly?)"; exit 1; }

cfg=$(jenkins_get /job/demo-api/config.xml 2>/dev/null) || { c_bad "demo-api is gone from Jenkins"; exit 1; }

# 0. The job's Script Path is the SAME for every branch. Changing it to match
#    one branch's file name breaks main (and every other branch) instead.
sp=$(sed -n 's|.*<scriptPath>\(.*\)</scriptPath>.*|\1|p' <<<"$cfg" | head -1)
if [[ $sp != Jenkinsfile ]]; then
  c_bad "demo-api's Script Path is now '$sp'. Every branch, main included, is looked up with that name: this fixes one branch by breaking the rest. Fix the branch instead."
  exit 1
fi

# 1. The branch has a job under demo-api.
if ! jenkins_get "/job/demo-api/job/$BRANCH_ENC/api/json?tree=name" >/dev/null 2>&1; then
  c_bad "still no job for $BRANCH under demo-api. Is Jenkins looking at the branch? Does it accept it? (read the scan log)"
  exit 1
fi
c_ok "demo-api has a job for $BRANCH"

# 2. Its last build is green, started after the incident, and is the branch's CURRENT tip.
b=$(jenkins_get "/job/demo-api/job/$BRANCH_ENC/lastBuild/api/json?tree=number,result,building,timestamp,actions%5BlastBuiltRevision%5BSHA1%5D,remoteUrls%5D" 2>/dev/null || echo '{}')
if [[ $b == '{}' ]]; then c_bad "the branch job exists but has never built (a new scan is needed, or still building)"; exit 1; fi
if [[ $(jq -r '.building' <<<"$b") == true ]]; then c_warn "the branch build is still running -- check again when it finishes"; exit 1; fi
ts=$(( $(jq -r '.timestamp // 0' <<<"$b") / 1000 ))
if (( ts < DRILL_STARTED )); then c_bad "the branch's last build predates the incident"; exit 1; fi
if [[ $(jq -r '.result' <<<"$b") != SUCCESS ]]; then
  c_bad "branch build #$(jq -r .number <<<"$b"): $(jq -r '.result' <<<"$b") -- read its console"; exit 1
fi
# The build also records the library checkout (platform-lib); take demo-api's.
built=$(jq -r '[.actions[]? | select(any(.remoteUrls[]?; test("payments/demo-api"))) | .lastBuiltRevision.SHA1? // empty][0] // ""' <<<"$b")
tip=$(head_sha payments/demo-api "$BRANCH" 2>/dev/null)
if [[ -z $built || $built != "$tip" ]]; then
  c_bad "the last green build is not the branch's current tip (${built:0:8} vs ${tip:0:8}) -- a newer commit is waiting for its build"; exit 1
fi
c_ok "branch build #$(jq -r .number <<<"$b") is SUCCESS on ${tip:0:8}, the branch's tip"

# 3. Nothing else was broken on the way: main still builds.
m=$(last_build main)
[[ $(jq -r '.result // "NONE"' <<<"$m") == FAILURE ]] && { c_bad "main's last build is FAILURE now"; exit 1; }
c_ok "main still builds"

# 4. How did you get there?
extra=$(items_outside_demo_api | grep -vxFf "$snap" || true)
if [[ -n $extra ]]; then
  echo "PENALTY 20 You made a separate job for one branch ($(tr '\n' ' ' <<<"$extra")). That is the 140-hand-made-jobs world Jordan was cleaning up, it does not follow the next branch, and it is not in code. Fix what discovers branches."
fi
d="$STATE/scratch/check46"; rm -rf "$d"
if git clone -q "$(repo_url payments/demo-api)" "$d" 2>/dev/null \
   && git -C "$d" merge-base --is-ancestor "origin/$BRANCH" origin/main 2>/dev/null; then
  echo "PENALTY 15 The branch's commits are on main. Getting a build by merging unreviewed work into the deploy branch skips the PR the CI was for."
fi
rm -rf "$d"
inc=$(sed -n 's|.*<includes>\(.*\)</includes>.*|\1|p' <<<"$cfg" | head -1)
if ! grep -q WildcardSCMHeadFilterTrait <<<"$cfg" || [[ $inc == '*' ]]; then
  echo "PENALTY 5 The name filter is gone (or matches everything): that fixes the ticket, but it puts back the 140 stale branch jobs Jordan removed. Widen it to the team's prefixes instead."
fi
