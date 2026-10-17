#!/usr/bin/env bash
# Put the demo-api job back as the Job DSL defines it (no branch properties),
# and remove the check's throwaway branch. The baseline CONTENT of demo-api is
# restored by `play reset` itself.
source "$(dirname "$0")/../../lib/common.sh"; load_creds
git push -q "$(repo_url payments/demo-api)" --delete drill45-probe >/dev/null 2>&1 || true
cfg=$(jenkins_get /job/demo-api/config.xml 2>/dev/null) || exit 0
grep -q NoTriggerBranchProperty <<<"$cfg" || exit 0
new=$(python3 - "$cfg" <<'PY'
import re, sys
print(re.sub(r'<properties class="java\.util\.Arrays\$ArrayList">.*?</properties>',
             '<properties class="empty-list"/>', sys.argv[1], count=1, flags=re.S))
PY
)
printf '%s' "$new" | jenkins_post -H 'Content-Type: application/xml' --data-binary @- \
  "$JENKINS_URL/job/demo-api/config.xml" -o /dev/null || true
exit 0
