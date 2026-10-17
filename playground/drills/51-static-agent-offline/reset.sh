#!/usr/bin/env bash
# Put back everything drill 51 changed: the job, the repo and clone, the agent
# (back to the state it had before the first static drill: baseline, or down),
# and the built-in node's executors. Safe to run when drill 51 was never played.
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
ORG=release REPO=release-signer JOB=release-signer
STATE_FILE="$STATE/drill51.state"
[[ -f $STATE_FILE ]] || exit 0

jenkins_groovy "jenkins.model.Jenkins.get().setNumExecutors(0); jenkins.model.Jenkins.get().save(); println 'built-in node: 0 executors'" >/dev/null 2>&1
job_drop "$JOB"
repo_drop "$ORG" "$REPO"
agent_restore_baseline
rm -f "$STATE_FILE"
exit 0
