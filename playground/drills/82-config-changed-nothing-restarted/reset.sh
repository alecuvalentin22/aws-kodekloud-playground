#!/usr/bin/env bash
# Remove what drill 82 created: the helm-drill-82 job, the payments/helm-drill-82
# repo and clone, the helm-drill-82 namespace (the release and its revision
# Secrets go with it), the chart tags in its own registry path, and the record.
# Does nothing if it was never started.
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
job_delete
gitea_api DELETE "/repos/$REPO" >/dev/null 2>&1 || true
HELM -n "$NS" uninstall "$REL" >/dev/null 2>&1 || true
K delete ns "$NS" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
charts_registry_cleanup
rm -rf "$CLONE" "$SF" "$STATE/scratch/seed$N" "$STATE/scratch/check$N" "$STATE/scratch/up$N"
exit 0
