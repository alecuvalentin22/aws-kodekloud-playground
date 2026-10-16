#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
as_teammate "Priya (payments)" payments/demo-api "Jenkinsfile: deploy to payments-staging" <<'SH'
python3 - <<'PY'
p = "Jenkinsfile"
s = open(p).read()
old = "    context: '.',\n"
assert old in s
s = s.replace(old, old + "    namespace: 'payments-staging',\n")
open(p, "w").write(s)
PY
SH
jenkins_scan
