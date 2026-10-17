#!/usr/bin/env bash
# check.sh -- did you build one job of each kind, and is each one green?
# Read-only: it asks Jenkins and Gitea questions, it changes nothing.
#
#   ./check.sh            (from this directory, on the box that runs the playground)
#
# Exit code 0 = every step passed. Each line says which step it is and, when
# it fails, what to look at. Not scored: there is no clock.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
PASS=0; FAIL=0

echo "Jenkins job-types exercise check -- $JENKINS_URL"
echo
echo "0. The playground"
if jenkins_get /api/json >/dev/null 2>&1; then ok "Jenkins answers and the login works"
else bad "Jenkins does not answer on $JENKINS_URL" "play doctor; setup/up.sh"; echo; echo "Stopped: nothing else can be checked."; exit 1; fi
if gitea_api GET "/repos/$REPO" >/dev/null 2>&1; then ok "$REPO exists in Gitea"
else bad "$REPO is missing" "./seed.sh"; fi

# need_job NAME CLASS -- the job exists and Jenkins says it is of that kind.
need_job() {
  local c; c=$(job_class "$1")
  if [[ -z $c ]]; then bad "no job named $1" "create it (README, this step)"; return 1; fi
  if [[ $c != "$2" ]]; then bad "$1 is a $c, expected $2" "wrong 'New Item' type: delete it and create it again"; return 1; fi
  ok "$1 exists and is a ${c##*.}"
}
# need_green NAME -- its last COMPLETED build succeeded.
need_green() {
  local r; r=$(last_result "$1")
  if [[ $r == SUCCESS ]]; then ok "$1: last build is SUCCESS"; return 0; fi
  bad "$1: last build is $r" "open the job, Build Now, read the console"; return 1
}
WF=org.jenkinsci.plugins.workflow.job.WorkflowJob
MB=org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject

echo; echo "1. (a) Freestyle: a form, no code"
if need_job jt-freestyle hudson.model.FreeStyleProject; then
  need_green jt-freestyle
  cfg=$(jenkins_get /job/jt-freestyle/config.xml 2>/dev/null)
  grep -q '<hudson.tasks.Shell>' <<<"$cfg" && ok "it has an 'Execute shell' build step" || bad "no 'Execute shell' build step" "Build Steps > Add build step > Execute shell"
  grep -q "<assignedNode>$AGENT_LABEL</assignedNode>" <<<"$cfg" && ok "it is restricted to the label $AGENT_LABEL (the controller has 0 executors)" \
    || bad "no 'Restrict where this project can be run' label" "label: $AGENT_LABEL"
fi

echo; echo "2. (b) Scripted pipeline: Groovy with node{}"
if need_job jt-scripted $WF; then
  need_green jt-scripted
  src=$(job_source jt-scripted)
  if grep -qE '^[[:space:]]*pipeline[[:space:]]*\{' <<<"$src"; then bad "jt-scripted is written as declarative (pipeline { })" "scripted is node { stage { } } without the pipeline block: examples/scripted.groovy"
  elif grep -qE 'node[[:space:]]*(\(|\{)' <<<"$src"; then ok "it is scripted: node { } with no pipeline { } block"
  else bad "no node { } found in jt-scripted" "examples/scripted.groovy"; fi
fi

echo; echo "3. (c) Declarative pipeline: the same, with structure"
if need_job jt-declarative $WF; then
  need_green jt-declarative
  src=$(job_source jt-declarative)
  grep -qE '^[[:space:]]*pipeline[[:space:]]*\{' <<<"$src" && grep -q 'stages' <<<"$src" && ok "it is declarative: pipeline { stages { } }" \
    || bad "jt-declarative is not a declarative pipeline" "examples/declarative.groovy"
  grep -qE '^[[:space:]]*post[[:space:]]*\{' <<<"$src" && ok "it has a post { } block" || bad "no post { } block" "post { always { } failure { } } is where notifications and rollbacks go"
fi

echo; echo "4. (d) Multibranch: one job per branch, found by scanning git"
if need_job jt-multibranch $MB; then
  br=$(jenkins_get "/job/jt-multibranch/api/json?tree=jobs%5Bname,lastCompletedBuild%5Bresult%5D%5D" 2>/dev/null)
  n=$(jq '.jobs | length' <<<"$br" 2>/dev/null || echo 0)
  if (( n >= 2 )); then ok "$n branches discovered: $(jq -r '[.jobs[].name] | join(", ")' <<<"$br")"
  else bad "only $n branch job(s) under jt-multibranch" "create a feature branch in ~/platform-playground/jobtypes-demo, push it, 'Scan Multibranch Pipeline Now'"; fi
  jq -e '[.jobs[].name] | index("main")' <<<"$br" >/dev/null 2>&1 && ok "main is one of them" || bad "no job for main" "the scan log tells you why (job page > Scan Multibranch Pipeline Log)"
  notgreen=$(jq -r '[.jobs[] | select((.lastCompletedBuild.result // "NONE") != "SUCCESS") | .name] | join(", ")' <<<"$br" 2>/dev/null)
  [[ -z $notgreen ]] && (( n > 0 )) && ok "every branch's last build is SUCCESS" || bad "not green yet: ${notgreen:-no builds}" "open the branch job's console"
fi

echo; echo "5. (e) Parameterized pipeline: a choice and a boolean"
if need_job jt-params $WF; then
  defs=$(jenkins_get "/job/jt-params/api/json?tree=property%5BparameterDefinitions%5Bname,type%5D%5D" 2>/dev/null | jq -r '[.property[]? | .parameterDefinitions[]? | "\(.type)"] | join(" ")')
  [[ $defs == *ChoiceParameterDefinition* ]] && ok "it has a choice parameter" || bad "no choice parameter registered" "run the job once: Jenkins only learns parameters from a RUN of the Jenkinsfile (the first-run trap)"
  [[ $defs == *BooleanParameterDefinition* ]] && ok "it has a boolean parameter" || bad "no boolean parameter registered" "same: run the job once after adding it"
  need_green jt-params
  lb=$(jenkins_get "/job/jt-params/lastCompletedBuild/api/json?tree=actions%5Bparameters%5Bname,value%5D%5D" 2>/dev/null | jq -r '[.actions[]? | .parameters[]? | .name] | length' 2>/dev/null || echo 0)
  (( lb >= 2 )) && ok "the last build was started WITH parameters (Build with Parameters)" || bad "the last build had no parameters" "use 'Build with Parameters' now that the form exists"
  first=$(jenkins_get "/job/jt-params/1/api/json?tree=actions%5Bparameters%5Bname%5D%5D" 2>/dev/null | jq -r '[.actions[]? | .parameters[]? | .name] | length' 2>/dev/null)
  [[ $first == 0 ]] && info "build #1 had no parameters: that is the first-run trap, seen" || true
fi

echo; echo "6. (f) Upstream / downstream with a parameter"
if need_job jt-downstream $WF && need_job jt-upstream $WF; then
  need_green jt-upstream
  ds=$(jenkins_get "/job/jt-downstream/api/json?tree=builds%5Bnumber,result,actions%5Bcauses%5BupstreamProject,upstreamBuild%5D,parameters%5Bname,value%5D%5D%5D%7B0,15%7D" 2>/dev/null)
  hit=$(jq -r '[.builds[]? | select(.result=="SUCCESS") | select([.actions[]? | .causes[]? | select(.upstreamProject=="jt-upstream")] | length > 0)] | first | .number // empty' <<<"$ds" 2>/dev/null)
  if [[ -n $hit ]]; then
    ok "jt-downstream #$hit was started by jt-upstream and succeeded"
    val=$(jq -r --argjson n "$hit" '.builds[] | select(.number==$n) | [.actions[]? | .parameters[]? | .value] | map(select(. != "")) | first // empty' <<<"$ds")
    [[ -n $val ]] && ok "the parameter arrived with a value: '$val'" || bad "jt-downstream #$hit received no parameter value" "the upstream's parameter name must match the downstream's; run the downstream by hand once first so the parameter exists"
  else
    bad "no successful jt-downstream build started by jt-upstream" "run jt-downstream once by hand FIRST (so its parameter exists), then run jt-upstream"
  fi
fi

echo; echo "7. (g) Declarative matrix"
if need_job jt-matrix $WF; then
  need_green jt-matrix
  src=$(job_source jt-matrix)
  grep -qE '^[[:space:]]*matrix[[:space:]]*\{' <<<"$src" && ok "it uses a matrix { } block" || bad "no matrix { } block in jt-matrix" "examples/matrix.groovy"
  cells=$(jenkins_get /job/jt-matrix/lastCompletedBuild/consoleText 2>/dev/null | grep -o "(Branch: Matrix - [^)]*)" | sort -u | wc -l | tr -d ' ')
  (( cells >= 4 )) && ok "$cells cells ran (the excludes{} removed the rest)" || bad "only $cells matrix cell(s) in the console" "expected the axes' combinations, 5 with the exclude in examples/matrix.groovy"
fi

echo; echo "8. (h) Jobs as code: Job DSL"
if jenkins_get /job/jt-seed/api/json >/dev/null 2>&1; then
  ok "jt-seed exists ($(job_class jt-seed | sed 's/.*\.//'))"
  need_green jt-seed
else bad "no job named jt-seed" "a freestyle job with Add build step > Process Job DSLs, script: jobs/dsl.groovy"; fi
need_job jt-dsl-pipeline $WF && need_green jt-dsl-pipeline
need_job jt-dsl-freestyle hudson.model.FreeStyleProject
if jenkins_get /job/jt-seed/lastBuild/consoleText 2>/dev/null | grep -q 'jt-dsl-pipeline'; then ok "the seed job's log lists the jobs it generated"; fi

echo; echo "9. Pipeline triggers"
if jenkins_get /job/jt-declarative/config.xml 2>/dev/null | grep -qE '<hudson.triggers.(SCMTrigger|TimerTrigger)'; then
  ok "jt-declarative has a trigger (poll SCM or cron) registered"
  if jenkins_get "/job/jt-declarative/api/json?tree=builds%5Bactions%5Bcauses%5BshortDescription%5D%5D%5D%7B0,15%7D" 2>/dev/null | grep -q 'SCM change\|timer'; then
    ok "and a build was started by it (not by you)"
  else
    bad "no build was started by the trigger yet" "push a commit to main in ~/platform-playground/jobtypes-demo and wait a minute or two"
  fi
else
  bad "jt-declarative has no pollSCM / cron trigger" "add  triggers { pollSCM('* * * * *') }  and RUN the job once so Jenkins registers it"
fi

echo; echo "Not exercised here (plugins missing on this Jenkins):"
for p in github-branch-source:"organization folders and PR builds (GitHub)" gitea:"organization folders and PR builds (Gitea)" parameterized-trigger:"'Trigger parameterized build' in freestyle jobs"; do
  if ! jenkins_get "/pluginManager/api/json?depth=1&tree=plugins%5BshortName%5D" 2>/dev/null | jq -e --arg s "${p%%:*}" '.plugins[] | select(.shortName==$s)' >/dev/null 2>&1; then
    info "${p%%:*} is not installed: ${p#*:}. Answer those in words (README, Q&A)."
  fi
done

echo
if (( FAIL == 0 )); then printf '\033[32mAll %d checks passed.\033[0m  Next: say the Q&A out loud, then ./cleanup.sh\n' "$PASS"; exit 0; fi
printf '\033[31m%d passed, %d to do.\033[0m\n' "$PASS" "$FAIL"; exit 1
