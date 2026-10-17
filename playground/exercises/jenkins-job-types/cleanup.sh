#!/usr/bin/env bash
# Remove everything the exercise created: its jobs, its repo, your clone.
# Only the names this exercise uses (see JT_JOBS in lib.sh); nothing else.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
for j in $JT_JOBS; do
  if jenkins_get "/job/$j/api/json" >/dev/null 2>&1; then
    jenkins_post "$JENKINS_URL/job/$j/doDelete" >/dev/null 2>&1 && c_ok "deleted job $j" || c_warn "could not delete $j"
  fi
done
if gitea_api GET "/repos/$REPO" >/dev/null 2>&1; then
  gitea_api DELETE "/repos/$REPO" >/dev/null 2>&1 && c_ok "deleted repo $REPO"
fi
# Step 7 had you approve the Job DSL script (an approved script HASH). The
# playground's baseline has no approved scripts, so take that back too.
jenkins_groovy 'import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval
ScriptApproval.get().clearApprovedScripts()
null' >/dev/null 2>&1 && c_ok "cleared approved scripts (the baseline has none)"
rm -rf "$WORK/jobtypes-demo" && c_ok "removed your clone"
