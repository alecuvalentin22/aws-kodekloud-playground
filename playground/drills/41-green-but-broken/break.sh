#!/usr/bin/env bash
# A real bug, then the "fix" that hides it: the pipeline stops being able to
# fail. Two commits from the same teammate, minutes apart.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds

# 1. A feature with a bug the unit test catches. SERVICE_NAME is not set in
#    k8s/deployment.yaml, so in production the app reports its name as null.
as_teammate "Priya (payments)" payments/demo-api "index: take the service name from SERVICE_NAME (platform naming)" <<'SH'
python3 - <<'PY'
p = "app.py"
s = open(p).read()
old = 'return jsonify(app="demo-api", version=VERSION)'
assert old in s
open(p, "w").write(s.replace(old, 'return jsonify(app=os.environ.get("SERVICE_NAME"), version=VERSION)'))
PY
SH

# 2. The test went red and blocked the release, so: unblock it. `|| true`
#    makes the shell step exit 0 whatever pytest says, and with no
#    --junitxml there is no report for Jenkins to turn into a failure --
#    standardPipeline publishes with allowEmptyResults: true.
as_teammate "Priya (payments)" payments/demo-api "Jenkinsfile: unblock the release, tests flaky on the shared runner" <<'SH'
python3 - <<'PY'
p = "Jenkinsfile"
s = open(p).read()
old = "    context: '.',\n"
assert old in s
new = old + ("    // TODO(priya): put the test gate back once the flaky one is fixed\n"
             "    testCommand: 'pip install -q -r requirements.txt && python -m pytest -q || true',\n")
open(p, "w").write(s.replace(old, new, 1))
PY
grep -q '|| true' Jenkinsfile
SH
jenkins_scan
