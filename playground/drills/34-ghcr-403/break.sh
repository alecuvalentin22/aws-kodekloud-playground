#!/usr/bin/env bash
# A teammate removes the publish job's own `permissions:` block as "redundant".
# The workflow level is `contents: read`, so the GHCR push is refused.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/github.sh"; gh_load_env
gh_as_teammate "$GH_APP1" "Jordan (platform)" "ci: drop per-job permissions from publish; workflow-level contents: read is enough" <<'SH'
python3 - <<'PY'
p = ".github/workflows/ci.yml"
s = open(p).read()
old = "    permissions:\n      contents: read\n      packages: write\n    env:\n"
assert old in s, "publish permissions block not found"
open(p, "w").write(s.replace(old, "    env:\n"))
PY
SH
gh_state_set drill34.bad-sha "$GH_LAST_SHA"
