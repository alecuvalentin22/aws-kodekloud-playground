#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
as_teammate "Jordan (platform)" platform/platform-lib "standardPipeline: rename context -> path, consistent with Backstage templates" <<'SH'
python3 - <<'PY'
p = "vars/standardPipeline.groovy"
s = open(p).read()
old = "String context  = cfg.context    ?: error('standardPipeline: context is required')"
assert old in s
s = s.replace(old, "String context  = cfg.path       ?: error('standardPipeline: path is required (renamed from context)')")
open(p, "w").write(s)
PY
SH
head_sha platform/platform-lib main > "$STATE/drill07.bad-sha"
jenkins_post "$JENKINS_URL/job/demo-api/job/main/build?delay=0" >/dev/null || true
