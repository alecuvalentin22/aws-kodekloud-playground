#!/usr/bin/env bash
# Sam pushed feature/refund-endpoint and no job appeared under demo-api. Two
# things stand in the way, one behind the other:
#   1. Jordan tidied the job in the UI: "Filter by name (with wildcards)" now
#      includes only `main release/*`. Indexing never even looks at feature/*.
#      (The job is defined by JCasC + Job DSL; this edit lives only in Jenkins
#      and would vanish at the next controller restart -- which is part of
#      the story.)
#   2. Sam's branch was cut on a Mac: the file is `jenkinsfile`, not `Jenkinsfile`.
#      Gitea and the agent are Linux, so the script path does not match.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"

# A clean start only.
if git ls-remote --exit-code --heads "$(repo_url payments/demo-api)" "$BRANCH" >/dev/null 2>&1; then
  echo "branch $BRANCH already exists -- run: play reset"; exit 1
fi
cfg=$(jenkins_get /job/demo-api/config.xml)
if grep -q WildcardSCMHeadFilterTrait <<<"$cfg"; then
  echo "demo-api already has a name filter -- run: play reset"; exit 1
fi

# What exists outside demo-api now: check.sh calls anything new a workaround.
items_outside_demo_api > "$STATE/drill46.items"

new=$(python3 - "$cfg" <<'PY'
import sys
s = sys.argv[1]
anchor = '<jenkins.plugins.git.traits.BranchDiscoveryTrait/>'
assert s.count(anchor) == 1, "unexpected demo-api branch-source config"
trait = ('<jenkins.scm.impl.trait.WildcardSCMHeadFilterTrait>'
         '<includes>main release/*</includes><excludes></excludes>'
         '</jenkins.scm.impl.trait.WildcardSCMHeadFilterTrait>')
print(s.replace(anchor, anchor + trait))
PY
)
printf '%s' "$new" | jenkins_post -H 'Content-Type: application/xml' --data-binary @- \
  "$JENKINS_URL/job/demo-api/config.xml" -o /dev/null
jenkins_get /job/demo-api/config.xml | grep -q WildcardSCMHeadFilterTrait

# Sam's branch: a real change with a test, and the Mac-case Jenkinsfile.
d="$STATE/scratch/break46"; rm -rf "$d"
git clone -q "$(repo_url payments/demo-api)" "$d"
(
  cd "$d"
  git checkout -q -b "$BRANCH"
  cat >> app.py <<'PY'


@app.get("/refunds/<refund_id>")
def refund(refund_id):
    return jsonify(id=refund_id, status="pending")
PY
  cat >> test_app.py <<'PY'


def test_refund_is_pending():
    body = client().get("/refunds/r-42").get_json()
    assert body == {"id": "r-42", "status": "pending"}
PY
  git mv Jenkinsfile jenkinsfile
  git add -A
  git -c user.name="Sam (payments)" -c user.email="teammate@playground.local" \
    commit -q -m "refunds: GET /refunds/<id> (pending for now)"
  git push -q origin "HEAD:refs/heads/$BRANCH"
)
rm -rf "$d"

# Let a scan see both facts, so "nothing happened" is already true.
jenkins_scan
sleep 15
