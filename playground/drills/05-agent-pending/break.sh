#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
as_teammate "Jordan (platform)" platform/platform-lib "agent pod: more memory for BuildKit (big Java builds)" <<'SH'
python3 - <<'PY'
p = "resources/podtemplates/build.yaml"
s = open(p).read()
old = "requests: {cpu: 250m, memory: 512Mi}\n        limits: {memory: 1536Mi}"
assert old in s
s = s.replace(old, "requests: {cpu: 250m, memory: 6Gi}\n        limits: {memory: 8Gi}")
open(p, "w").write(s)
PY
SH
# A library change triggers nothing by itself -- the next app build picks it up.
jenkins_post "$JENKINS_URL/job/demo-api/job/main/build?delay=0" >/dev/null || true
