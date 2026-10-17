#!/usr/bin/env bash
# Helper for the static-vs-dynamic exercise.
#
#   ./lab.sh seed     bring the static agent up (setup/static-agent.sh up) and
#                     create the jobs sva-static, sva-dynamic, sva-snoop
#   ./lab.sh status   the jobs, their last builds, the agent
#   ./lab.sh clean    delete the jobs (and your notes are left alone); --agent
#                     also takes the static agent down so Docker is free again
#
# The jobs are plain Pipeline jobs with the script IN the job, so you can open
# Configure and change the agent line. The source of each is in ./pipelines/.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/common.sh"; load_creds
JOBS="sva-static sva-dynamic sva-snoop"

job_put() {   # job_put NAME FILE
  local name=$1 file=$2 x="$STATE/scratch/sva-$1.xml"
  mkdir -p "$STATE/scratch"
  {
    echo '<?xml version="1.1" encoding="UTF-8"?><flow-definition plugin="workflow-job">'
    echo '<description>Exercise static-vs-dynamic-agents. Removed by lab.sh clean.</description><keepDependencies>false</keepDependencies>'
    echo '<definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps"><script>'
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$file"
    echo '</script><sandbox>true</sandbox></definition><triggers/><disabled>false</disabled></flow-definition>'
  } > "$x"
  if jenkins_get "/job/$name/api/json" >/dev/null 2>&1; then
    jenkins_post -H 'Content-Type: application/xml' --data-binary "@$x" "$JENKINS_URL/job/$name/config.xml" >/dev/null
  else
    jenkins_post -H 'Content-Type: application/xml' --data-binary "@$x" "$JENKINS_URL/createItem?name=$name" >/dev/null
  fi
  rm -f "$x"
}

case "${1:-}" in
  seed)
    bash "$PG_ROOT/setup/static-agent.sh" up
    for j in $JOBS; do job_put "$j" "$HERE/pipelines/$j.groovy"; c_ok "job $j  $JENKINS_URL/job/$j/"; done
    echo; echo "  Next: README.md step 1." ;;
  status)
    for j in $JOBS; do
      printf "  %-12s " "$j"
      jenkins_get "/job/$j/api/json?tree=builds[number,result]" 2>/dev/null | jq -r '[.builds[:5][] | "#\(.number) \(.result // "running")"] | join(", ")' 2>/dev/null || echo "(no such job: ./lab.sh seed)"
    done
    bash "$PG_ROOT/setup/static-agent.sh" status ;;
  clean)
    for j in $JOBS; do
      jenkins_groovy "def p = jenkins.model.Jenkins.get().getItem('$j'); if (p) { p.builds.each { if (it.isBuilding()) { it.doStop() } }; sleep(1500); p.delete(); println 'deleted $j' }" | sed 's/^/  /'
    done
    [[ ${2:-} == --agent ]] && bash "$PG_ROOT/setup/static-agent.sh" down
    c_ok "exercise jobs removed" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
