#!/usr/bin/env bash
# Remove `set +x` from the ECR login step: Jenkins runs sh with -x, so the
# minted token is echoed into the console. drills/18 section 1b, on purpose.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"; load_creds
as_teammate "Jordan (platform)" platform/platform-lib "buildImage: re-enable tracing in the ECR login step for debugging" <<'SH'
python3 - <<'PY'
p = "vars/buildImage.groovy"
s = open(p).read()
old = '                    set +x\n                    set -eu\n                    mkdir -p'
assert old in s, "set +x block not found"
open(p, "w").write(s.replace(old, '                    set -eu\n                    mkdir -p', 1))
PY
SH
jenkins_post "$JENKINS_URL/job/demo-api/job/main/build?delay=0" >/dev/null || true
