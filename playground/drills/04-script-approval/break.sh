#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
as_teammate "Alex (payments)" payments/demo-api "Jenkinsfile: short sha in the build name for QA" <<'SH'
python3 - <<'PY'
p = "Jenkinsfile"
s = open(p).read()
s = s.replace("@Library('platform-lib') _\n", """@Library('platform-lib') _

// QA wants the short commit in the build name
def shortSha = 'git rev-parse --short HEAD'.execute().text.trim()
currentBuild.displayName = "#${env.BUILD_NUMBER} ${shortSha}"
""", 1)
open(p, "w").write(s)
PY
grep -q execute Jenkinsfile
SH
jenkins_scan
