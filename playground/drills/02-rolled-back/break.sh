#!/usr/bin/env bash
# A config change that turns the readiness endpoint red. Tests pass because
# the unit tests do not run the deployment manifest.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
as_teammate "Priya (payments)" payments/demo-api "deploy: enable strict health mode for the new cache" <<'SH'
python3 - <<'PY'
import re
p = "k8s/deployment.yaml"
s = open(p).read()
s2 = s.replace('value: "false"', 'value: "true"', 1)
assert s2 != s
open(p, "w").write(s2)
PY
SH
jenkins_scan
