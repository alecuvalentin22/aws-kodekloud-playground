#!/usr/bin/env bash
# Remove what drill 09 and the player added, and ONLY that:
#   - platform-lib tags that are not in the snapshot break.sh took (and never
#     `baseline` or `v1.0.0`, whatever the snapshot says)
#   - the search-indexer and lib-check-09 jobs
# platform-lib's main and demo-api's Jenkinsfile are put back by `play reset`
# itself, as new commits. Does nothing if drill 09 was never started.
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
snap="$STATE/drill09.tags"
[[ -f $snap ]] || exit 0
for t in $(gitea_api GET "/repos/platform/platform-lib/tags?limit=50" | jq -r '.[].name'); do
  case $t in baseline|v1.0.0) continue ;; esac
  grep -q "^$t " "$snap" && continue
  gitea_api DELETE "/repos/platform/platform-lib/tags/$t" >/dev/null && echo "deleted platform-lib tag $t"
done
job_delete "$SEARCH_JOB"
job_delete lib-check-09
rm -f "$snap"
