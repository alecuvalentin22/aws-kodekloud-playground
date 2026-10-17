#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"

# 1. The latest rel-build: finished, green, started after the incident.
a=$(jenkins_get "/job/$JOBA/lastBuild/api/json?tree=number,result,building,timestamp" 2>/dev/null || echo '{}')
[[ $a == '{}' ]] && { c_bad "$JOBA has no builds"; exit 1; }
if [[ $(jq -r .building <<<"$a") == true ]]; then c_warn "$JOBA #$(jq -r .number <<<"$a") is still running -- check again when it finishes"; exit 1; fi
n=$(jq -r .number <<<"$a")
if (( $(jq -r '.timestamp' <<<"$a") / 1000 < DRILL_STARTED )); then c_bad "no $JOBA run since the incident started"; exit 1; fi
if [[ $(jq -r .result <<<"$a") != SUCCESS ]]; then c_bad "$JOBA #$n: $(jq -r .result <<<"$a") -- read its console"; exit 1; fi
c_ok "$JOBA #$n is SUCCESS"

# 2. Which image did THAT build push?
con=$(jenkins_get "/job/$JOBA/$n/consoleText" 2>/dev/null)
ref=$(sed -n 's/.*pushing manifest for \([^ ]*\)@sha256:.*/\1/p' <<<"$con" | head -1)
[[ -z $ref ]] && ref=$(sed -n 's/^.*BUILT \([^ ]*\)$/\1/p' <<<"$con" | head -1)
tag=${ref##*:}
if [[ -z $ref || $ref != *"/payments/relsvc:"* ]]; then c_bad "cannot tell which image $JOBA #$n pushed (looked for 'pushing manifest for ...payments/relsvc:TAG')"; exit 1; fi
digest=$(registry_digest "$tag")
[[ -n $digest ]] || { c_bad "$ref is not in the registry"; exit 1; }
c_ok "$JOBA #$n pushed $ref ($digest)"

# 3. The rel-deploy run that rel-build #n STARTED (a run you did by hand does not count).
bs=$(jenkins_get "/job/$JOBB/api/json?tree=builds%5Bnumber,result,building,actions%5Bcauses%5BupstreamProject,upstreamBuild%5D,parameters%5Bname,value%5D%5D%5D%7B0,25%7D" 2>/dev/null || echo '{"builds":[]}')
b=$(jq -c --argjson n "$n" --arg a "$JOBA" '[.builds[] | select([.actions[]? | .causes[]? | select(.upstreamProject==$a and .upstreamBuild==$n)] | length > 0)] | first // empty' <<<"$bs")
[[ -n $b ]] || { c_bad "$JOBA #$n never started a $JOBB run"; exit 1; }
if [[ $(jq -r .building <<<"$b") == true ]]; then c_warn "$JOBB #$(jq -r .number <<<"$b") is still running -- check again when it finishes"; exit 1; fi
bn=$(jq -r .number <<<"$b")
[[ $(jq -r .result <<<"$b") == SUCCESS ]] || { c_bad "$JOBB #$bn (started by $JOBA #$n): $(jq -r .result <<<"$b")"; exit 1; }
got=$(jq -r '[.actions[]? | .parameters[]? | "\(.name)=\(.value)"] | join(" ")' <<<"$b")
if [[ $(jq -r --arg t "$tag" '[.actions[]? | .parameters[]? | .value] | index($t) // empty' <<<"$b") == "" ]]; then
  c_bad "$JOBB #$bn was started by $JOBA #$n but was never told to deploy $tag (it recorded: ${got:-no parameters})"
  exit 1
fi
c_ok "$JOBB #$bn was told the exact tag: $got"

# 4. And the cluster agrees, by digest, not by name.
spec=$(K -n "$NS48" get deploy relsvc -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
K -n "$NS48" rollout status deploy/relsvc --timeout=60s >/dev/null 2>&1 || { c_bad "relsvc in $NS48 is not fully rolled out"; exit 1; }
ids=$(K -n "$NS48" get pods -l app=relsvc -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}' 2>/dev/null | grep -v '^$' | sort -u)
if [[ -z $ids ]] || grep -qvF "$digest" <<<"$ids"; then
  c_bad "relsvc is running $(tr '\n' ' ' <<<"$ids") -- not the image $JOBA #$n built ($digest)"
  exit 1
fi
c_ok "relsvc runs exactly that image ($spec)"

# 5. How did you get there?
if [[ $tag == latest || $spec == *:latest ]]; then
  echo "PENALTY 25 The fix is 'deploy latest'. A moving tag cannot tell you which build is running, cannot be rolled back to, and the next build silently changes what 'latest' means. Pass the exact tag (or digest)."
fi
exit 0
