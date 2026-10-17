# shellcheck shell=bash
# Helpers for drill 09 only (sourced after lib/common.sh): tiny inline pipeline
# jobs, created through the Jenkins API.

# job_put NAME 'groovy script' -- create the job, or update it if it exists.
job_put() {
  local name=$1 script=$2 f="$STATE/scratch/job09-$1.xml"
  mkdir -p "$STATE/scratch"
  {
    echo '<?xml version="1.1" encoding="UTF-8"?><flow-definition plugin="workflow-job">'
    echo '<description>Drill 09 helper job. Removed by play reset.</description><keepDependencies>false</keepDependencies>'
    echo '<definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps"><script>'
    printf '%s\n' "$script" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
    echo '</script><sandbox>true</sandbox></definition><triggers/><disabled>false</disabled></flow-definition>'
  } > "$f"
  if jenkins_get "/job/$name/api/json" >/dev/null 2>&1; then
    jenkins_post -H 'Content-Type: application/xml' --data-binary "@$f" "$JENKINS_URL/job/$name/config.xml" >/dev/null
  else
    jenkins_post -H 'Content-Type: application/xml' --data-binary "@$f" "$JENKINS_URL/createItem?name=$name" >/dev/null
  fi
  local rc=$?; rm -f "$f"; return $rc
}

job_delete() { jenkins_post "$JENKINS_URL/job/$1/doDelete" >/dev/null 2>&1 || true; }

# job_run NAME OUTFILE [seconds] -- build once, wait, save the console to OUTFILE
# and leave the result (SUCCESS, FAILURE, ... or TIMEOUT) in JOB_RESULT.
job_run() {
  local name=$1 out=$2 limit=${3:-150} n t0 b
  n=$(jenkins_get "/job/$name/api/json?tree=nextBuildNumber" | jq -r .nextBuildNumber) || return 1
  jenkins_post "$JENKINS_URL/job/$name/build?delay=0" >/dev/null || return 1
  t0=$(date +%s); JOB_RESULT=TIMEOUT
  while (( $(date +%s) - t0 < limit )); do
    b=$(jenkins_get "/job/$name/$n/api/json?tree=building,result" 2>/dev/null || true)
    if [[ -n $b && $(jq -r .building <<<"$b") == false ]]; then JOB_RESULT=$(jq -r '.result' <<<"$b"); break; fi
    sleep 2
  done
  jenkins_get "/job/$name/$n/consoleText" > "$out" 2>/dev/null || : > "$out"
}

# search-indexer: another team, a plain pipeline job pinned to v1.0.0.
SEARCH_JOB=search-indexer
SEARCH_SCRIPT="@Library('platform-lib@v1.0.0') _
import org.platformlab.ImageTag
echo \"search-indexer on platform-lib v1.0.0, image tag \${ImageTag.of('main', 'abcdef0123456789', '7')}\""
