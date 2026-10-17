#!/usr/bin/env bash
# Remove what drill 48 created: the rel-build and rel-deploy jobs, the
# payments/rel-pipelines repo and clone, and the rel-demo namespace. Images
# pushed to payments/relsvc stay in the registry (harmless, and the registry
# has no garbage collection). Does nothing if it was never started.
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
jenkins_post "$JENKINS_URL/job/$JOBA/doDelete" >/dev/null 2>&1 || true
jenkins_post "$JENKINS_URL/job/$JOBB/doDelete" >/dev/null 2>&1 || true
gitea_api DELETE "/repos/$REPO48" >/dev/null 2>&1 || true
K delete ns "$NS48" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
rm -rf "$WORK/rel-pipelines"
exit 0
