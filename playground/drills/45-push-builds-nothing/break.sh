#!/usr/bin/env bash
# The job's definition is code (JCasC + Job DSL), and this edit lives only in
# the UI: Jordan added the branch property "Suppress automatic SCM triggering"
# to demo-api's branch source. Indexing still SEES every push; it just never
# schedules the build. Then a teammate pushes a commit that should have built.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds

cfg=$(jenkins_get /job/demo-api/config.xml)
new=$(python3 - "$cfg" <<'PY'
import sys
s = sys.argv[1]
old = '<properties class="empty-list"/>'
assert s.count(old) == 1, "unexpected demo-api branch-source config"
print(s.replace(old, '<properties class="java.util.Arrays$ArrayList"><a class="jenkins.branch.BranchProperty-array">'
                     '<jenkins.branch.NoTriggerBranchProperty/></a></properties>'))
PY
)
printf '%s' "$new" | jenkins_post -H 'Content-Type: application/xml' --data-binary @- \
  "$JENKINS_URL/job/demo-api/config.xml" -o /dev/null
jenkins_get /job/demo-api/config.xml | grep -q NoTriggerBranchProperty

# Saving the job config re-indexes once; let that finish, then push the commit
# that should have built.
sleep 8
as_teammate "Sam (payments)" payments/demo-api "README: link the runbook" <<'SH'
printf '\nRunbook: https://wiki.playground.local/payments/demo-api\n' >> README.md
SH

# Wait (best effort) until a scan has seen the commit and declined to build it,
# so "the push did nothing" is already true when the candidate starts.
for _ in $(seq 1 14); do
  scanlog=$(jenkins_get /job/demo-api/indexing/consoleText 2>/dev/null || true)
  grep -q 'Did not schedule build for branch: main' <<<"$scanlog" && break
  sleep 8
done
exit 0
