# shellcheck shell=bash
# Shared by the exercise's scripts. Source it; do not run it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/common.sh"
load_creds

REPO=payments/jobtypes-demo
AGENT_LABEL=jenkins-jenkins-agent     # the Kubernetes plugin's default pod template (chart release 'jenkins')

# Every job this exercise can create. cleanup.sh deletes exactly these.
JT_JOBS="jt-freestyle jt-scripted jt-declarative jt-multibranch jt-params jt-downstream jt-upstream jt-matrix jt-seed jt-dsl-pipeline jt-dsl-freestyle"

ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓ %s\033[0m\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; [ -n "${2:-}" ] && printf '      hint: %s\n' "$2"; }
info() { printf '  - %s\n' "$1"; }

# job_json NAME [TREE] -- JSON of a job (top-level), or fail.
job_json() { jenkins_get "/job/$1/api/json${2:+?tree=$2}" 2>/dev/null; }
job_class() { job_json "$1" | jq -r '._class // empty' 2>/dev/null; }
# The last COMPLETED build's result of a (non-multibranch) job, or NONE.
last_result() {
  jenkins_get "/job/$1/lastCompletedBuild/api/json?tree=result" 2>/dev/null | jq -r '.result // "NONE"' 2>/dev/null || echo NONE
}
# job_source NAME -- the pipeline text of a Pipeline job: inline script, or the
# Jenkinsfile it points at in Gitea (Pipeline script from SCM).
job_source() {
  local cfg path
  cfg=$(jenkins_get "/job/$1/config.xml" 2>/dev/null) || return 1
  if grep -q '<scriptPath>' <<<"$cfg"; then
    path=$(sed -n 's|.*<scriptPath>\(.*\)</scriptPath>.*|\1|p' <<<"$cfg" | head -1)
    curl -fsS "$GITEA_URL/$REPO/raw/branch/main/$path" 2>/dev/null
  else
    python3 -c 'import sys,re,html; s=sys.stdin.read(); m=re.search(r"<script>(.*?)</script>", s, re.S); print(html.unescape(m.group(1)) if m else "")' <<<"$cfg"
  fi
}
