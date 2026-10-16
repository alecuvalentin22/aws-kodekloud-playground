#!/usr/bin/env bash
# Drop the chown that lets rootless BuildKit (uid 1000) read the ECR login the
# root `deploy` container wrote. drills/18 section 1, reproduced on purpose.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"; load_creds
as_teammate "Jordan (platform)" platform/platform-lib "buildImage: drop redundant chown (config.json is mode 600 already)" <<'SH'
python3 - <<'PY'
p = "vars/buildImage.groovy"
s = open(p).read()
old = "                    chown -R 1000:1000 '${dockerCfg}'\n"
assert old in s, "chown line not found"
open(p, "w").write(s.replace(old, ""))
PY
SH
jenkins_post "$JENKINS_URL/job/demo-api/job/main/build?delay=0" >/dev/null || true
