#!/usr/bin/env bash
# Remove everything the exercise created: the Jenkins job, the repo, your clone,
# and the cicd-staging / cicd-prod namespaces (with everything running in them).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
if jenkins_get "/job/$JOB/api/json" >/dev/null 2>&1; then
  jenkins_post "$JENKINS_URL/job/$JOB/doDelete" >/dev/null 2>&1 && c_ok "deleted job $JOB" || c_warn "could not delete job $JOB"
fi
if gitea_api GET "/repos/$REPO" >/dev/null 2>&1; then
  gitea_api DELETE "/repos/$REPO" >/dev/null 2>&1 && c_ok "deleted repo $REPO"
fi
for ns in "$NS_STAGING" "$NS_PROD"; do
  K delete ns "$ns" --ignore-not-found --timeout=120s >/dev/null 2>&1 && c_ok "deleted namespace $ns"
done
rm -rf "$WORK/cicd-demo" && c_ok "removed your clone"
echo "  (images pushed to payments/cicd-demo stay in the local registry: harmless)"
