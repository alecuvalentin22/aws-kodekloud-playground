#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
approved=$(jenkins_groovy 'println org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval.get().approvedSignatures.join("\n")')
assert_main_green_since "$DRILL_STARTED" || exit 1
jf=$(curl -fsS "$GITEA_URL/payments/demo-api/raw/branch/main/Jenkinsfile")
if grep -q '\.execute(' <<<"$jf"; then c_bad "the Jenkinsfile still shells out with String.execute()"; exit 1; fi
c_ok "no String.execute() in the Jenkinsfile"
if grep -qi 'execute' <<<"$approved"; then
  c_warn "an execute() signature is approved: $(grep -i execute <<<"$approved" | head -1)"
  echo "PENALTY 40 You approved arbitrary process execution ON THE CONTROLLER for every pipeline. Revoke it."
else
  c_ok "nothing dangerous approved in script security"
fi
name=$(jenkins_get "/job/demo-api/job/main/lastSuccessfulBuild/api/json?tree=displayName" | jq -r .displayName)
if [[ $name =~ [0-9a-f]{7,8} ]]; then c_ok "QA got their build name: $name"
else c_warn "build name is '$name' -- QA's request is not done yet (no penalty, but the ticket is still open)"; fi
