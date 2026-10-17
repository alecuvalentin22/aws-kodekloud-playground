#!/usr/bin/env bash
# check.sh -- did you build the full pipeline, and does it behave?
# Read-only: it asks Jenkins, Gitea and kubectl questions and changes nothing.
#
#   ./check.sh            (from this directory, on the box that runs the playground)
#
# Exit code 0 = every step passed. Not scored: there is no clock.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
PASS=0; FAIL=0

echo "Full CI/CD exercise check -- job $JOB on $JENKINS_URL"
echo
echo "0. The playground"
jenkins_get "/job/$JOB/api/json" >/dev/null 2>&1 && ok "Jenkins job $JOB exists" || { bad "no Jenkins job $JOB" "./seed.sh"; echo; echo "Stopped."; exit 1; }
for ns in "$NS_STAGING" "$NS_PROD"; do
  K get ns "$ns" >/dev/null 2>&1 && ok "namespace $ns exists" || bad "namespace $ns is missing" "./seed.sh"
done

echo; echo "1. The Jenkinsfile on main (what the pipeline is made of)"
jf=$(curl -fsS "$GITEA_URL/$REPO/raw/branch/main/Jenkinsfile" 2>/dev/null)
[[ -n $jf ]] || { bad "cannot read the Jenkinsfile from $REPO main" "did you git push?"; echo; echo "Stopped."; exit 1; }
has() { grep -qE "$1" <<<"$jf"; }
has '^[[:space:]]*agent[[:space:]]+none' && ok "agent none at the top: each stage asks for its own agent" || bad "no top-level 'agent none'" "otherwise one pod is held for the whole run, including the wait for approval"
has 'junit' && ok "test results are published with junit" || bad "no junit step" "step 2"
has 'buildImage' && ok "the image is built with the library's buildImage" || bad "no buildImage call" "step 3"
if grep -qE ':latest|tag: *.latest.' <<<"$jf"; then bad "the Jenkinsfile mentions 'latest'" "tag the image with the git commit"; else ok "no 'latest' tag anywhere"; fi
has 'rollout status' && ok "deploys wait with kubectl rollout status" || bad "no 'kubectl rollout status'" "apply returns before the pods are healthy: wait for them"
has 'input[[:space:]]*(\(|id|message)' && has 'timeout *\(' && ok "approval is input inside a timeout" || bad "no input + timeout" "step 6"
has 'rollout undo' && has 'failure' && ok "post { failure } rolls prod back with rollout undo" || bad "no rollout undo in a failure block" "step 7"
has 'stash' && has 'unstash' && ok "manifests travel to the prod stage with stash/unstash" || info "no stash/unstash: the prod stage deploys whatever main is by then (README, step 7)"

echo; echo "2. The last green run"
S=$(jenkins_get "/job/$JOB/lastSuccessfulBuild/api/json?tree=number" 2>/dev/null | jq -r '.number // empty')
if [[ -z $S ]]; then
  bad "no successful build of $JOB yet" "run it, approve the prod stage, let it finish"
else
  sha=$(build_sha "$S")
  ok "build #$S, commit $sha"
  stages=$(jenkins_get "/job/$JOB/$S/wfapi/describe" 2>/dev/null | jq -r '[.stages[].name] | join("|")')
  for pat in 'test' 'image|build' 'staging' 'smoke' 'approv|promot' 'prod'; do
    grep -qiE "$pat" <<<"$stages" && ok "has a stage for /$pat/" || bad "no stage matching /$pat/ (stages: $stages)"
  done
  tc=$(jenkins_get "/job/$JOB/$S/testReport/api/json?tree=passCount,failCount,skipCount" 2>/dev/null | jq -r '(.passCount // 0) + (.failCount // 0) + (.skipCount // 0)')
  (( tc > 0 )) && ok "Jenkins shows $tc unit tests for the build (junit)" || bad "the build has no test report" "junit 'test-results.xml' and pytest --junitxml"
  # Was the approval outside any agent? Walk the console's block structure up to the input step.
  verdict=$(jenkins_get "/job/$JOB/$S/consoleText" 2>/dev/null | python3 -c '
import sys
stack, last, found = [], "", None
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.startswith("[Pipeline] "): continue
    w = line[len("[Pipeline] "):]
    if w.startswith("{"): stack.append(last)
    elif w.startswith("}"):
        if stack: stack.pop()
    elif w.startswith("//"): pass
    else:
        last = w.split(" ")[0]
        if last == "input": found = "node" in stack; break
print("none" if found is None else ("inside" if found else "outside"))')
  case $verdict in
    outside) ok "the input step ran outside any node/agent block (no pod held while waiting)" ;;
    inside)  bad "the input step ran INSIDE an agent: the pod is held for as long as nobody clicks" "give that stage no agent (agent none at the top, an agent only on the stages that need one)" ;;
    *)       bad "no input step in the last green run" "step 6" ;;
  esac

  echo; echo "3. The cluster: both namespaces ran the same commit"
  [[ $sha =~ ^[0-9a-f]{8}$ ]] || bad "cannot read the commit of build #$S"
  if ns_images "$NS_STAGING" | grep -qx "$sha"; then ok "$NS_STAGING has run image tag $sha"; else bad "$NS_STAGING never ran $sha (it has: $(ns_images "$NS_STAGING" | tr '\n' ' '))"; fi
  cur=$(ns_current "$NS_PROD")
  if [[ $cur == "$sha" ]]; then ok "$NS_PROD runs $sha: the image tag is the git commit of the last green build"
  else bad "$NS_PROD runs '$cur', expected $sha (the last green build's commit)" "did the prod stage run? did a failed release leave prod on the wrong build?"; fi
  K -n "$NS_PROD" rollout status deploy/cicd-demo --timeout=10s >/dev/null 2>&1 && ok "prod is fully rolled out and healthy" || bad "prod is not healthy"
  curl_out=$(K -n "$NS_PROD" get deploy cicd-demo -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  info "prod image: $curl_out"

  echo; echo "4. A bad release is rolled back by the pipeline"
  F=$(jenkins_get "/job/$JOB/api/json?tree=builds%5Bnumber,result%5D%7B0,25%7D" 2>/dev/null \
      | jq -r --argjson s "$S" '[.builds[] | select(.result=="FAILURE" and .number > $s)] | first | .number // empty')
  if [[ -z $F ]]; then
    bad "no failed release after build #$S" "step 8: push a release that is healthy in staging and not in prod, approve it, and watch it fail"
  else
    fsha=$(build_sha "$F")
    ok "build #$F failed (commit $fsha)"
    if ns_images "$NS_PROD" | grep -qx "$fsha"; then ok "that release did reach prod (its ReplicaSet exists in $NS_PROD)"; else bad "build #$F never reached prod, so it proves no rollback" "it must pass staging and the approval, then fail in prod"; fi
    if [[ $cur != "$fsha" ]]; then ok "and prod is NOT running it any more"; else bad "prod is running the bad release $fsha"; fi
    fcon=$(jenkins_get "/job/$JOB/$F/consoleText" 2>/dev/null)
    if grep -q 'rolled back' <<<"$fcon"; then ok "the console shows kubectl rolling prod back automatically"; else bad "no 'rolled back' in build #$F's console" "post { failure } must run: kubectl rollout undo"; fi
    jenkins_get "/job/$JOB/$F/wfapi/describe" 2>/dev/null | jq -e '[.stages[] | select((.name|test("prod";"i")) and (.name|test("approv|promot";"i")|not)) | .status] | any(. == "FAILED")' >/dev/null 2>&1 \
      && ok "the prod stage is the red one (staging was healthy)" || bad "build #$F did not fail in the prod stage" "the bad release must be fine in staging (MODE=relaxed) and fail in prod (MODE=strict)"
  fi
fi

echo
if (( FAIL == 0 )); then printf '\033[32mAll %d checks passed.\033[0m  Next: say the Q&A out loud, then ./cleanup.sh\n' "$PASS"; exit 0; fi
printf '\033[31m%d passed, %d to do.\033[0m\n' "$PASS" "$FAIL"; exit 1
