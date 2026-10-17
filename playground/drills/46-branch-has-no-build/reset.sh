#!/usr/bin/env bash
# Put demo-api's branch source back as the Job DSL defines it (no name filter,
# Script Path Jenkinsfile), delete Sam's branch and its Jenkins job, and any
# job the player made for it. The baseline CONTENT of demo-api is restored by
# `play reset` itself. Does nothing if drill 46 was never started.
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
snap="$STATE/drill46.items"
[[ -f $snap ]] || exit 0

cfg=$(jenkins_get /job/demo-api/config.xml 2>/dev/null) || cfg=
if [[ -n $cfg ]]; then
  new=$(python3 - "$cfg" <<'PY'
import re, sys
s = sys.argv[1]
t = 'jenkins.scm.impl.trait.WildcardSCMHeadFilterTrait'
s = re.sub(r'<%s[^>]*?/>|<%s[^>]*>.*?</%s>' % (t, t, t), '', s, flags=re.S)
s = re.sub(r'<scriptPath>.*?</scriptPath>', '<scriptPath>Jenkinsfile</scriptPath>', s)
print(s)
PY
)
  printf '%s' "$new" | jenkins_post -H 'Content-Type: application/xml' --data-binary @- \
    "$JENKINS_URL/job/demo-api/config.xml" -o /dev/null || true
fi

git push -q "$(repo_url payments/demo-api)" --delete "$BRANCH" >/dev/null 2>&1 || true
# A branch job can only be deleted once Jenkins knows its branch is gone
# (otherwise: "admin is missing the Job/Delete permission"): scan, then delete.
jenkins_scan
for _ in $(seq 1 20); do
  jenkins_get "/job/demo-api/job/$BRANCH_ENC/api/json?tree=name" >/dev/null 2>&1 || break
  jenkins_post "$JENKINS_URL/job/demo-api/job/$BRANCH_ENC/doDelete" >/dev/null 2>&1 && break
  sleep 3
done
for it in $(items_outside_demo_api | grep -vxFf "$snap" || true); do
  jenkins_post "$JENKINS_URL/job/$(sed 's|/|/job/|g' <<<"$it")/doDelete" >/dev/null 2>&1 || true
done
# The player's clone: forget the drill's branch, so a second round starts clean.
if [[ -d "$WORK/demo-api/.git" ]]; then
  git -C "$WORK/demo-api" checkout -q main 2>/dev/null || true
  git -C "$WORK/demo-api" branch -D "$BRANCH" >/dev/null 2>&1 || true
  git -C "$WORK/demo-api" fetch -q --prune origin >/dev/null 2>&1 || true
fi
rm -f "$snap"
