#!/usr/bin/env bash
# Remove what drill 47 created: the payments-release job, the payments/release-job
# repo and the player's clone of it. Does nothing if it was never started.
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
jenkins_post "$JENKINS_URL/job/$JOB47/doDelete" >/dev/null 2>&1 || true
gitea_api DELETE "/repos/$REPO47" >/dev/null 2>&1 || true
rm -rf "$WORK/release-job" "$STATE/scratch/check47.console"
exit 0
