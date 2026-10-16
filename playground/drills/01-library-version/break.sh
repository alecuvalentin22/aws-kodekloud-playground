#!/usr/bin/env bash
# The wiki says @v2. The library has only ever been tagged v1.0.0.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
as_teammate "Sam (payments)" payments/demo-api "Jenkinsfile: match the wiki example" <<'SH'
sed -i.bak "s/@Library('platform-lib') _/@Library('platform-lib@v2') _/" Jenkinsfile && rm Jenkinsfile.bak
grep -q "platform-lib@v2" Jenkinsfile
SH
jenkins_scan
