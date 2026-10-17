#!/usr/bin/env bash
# A teammate "saves minutes" with a path filter copied from a repo whose code is
# in src/. This repo's code is in service/, so no PR ever matches. Then Sam opens
# a PR that changes service/app.py and gets nothing.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/github.sh"; gh_load_env
r=$GH_APP1
gh_as_teammate "$r" "Jordan (platform)" "ci: only run PR checks when code changes (save runner minutes)" <<'SH'
python3 - <<'PY'
p = ".github/workflows/ci.yml"
s = open(p).read()
old = '    paths-ignore:\n      - "**.md"\n      - "docs/**"\n'
assert old in s, "paths-ignore block not found"
open(p, "w").write(s.replace(old, '    paths:\n      - "src/**"\n      - "tests/**"\n'))
PY
SH
gh_state_set drill31.bad-sha "$GH_LAST_SHA"
gh_as_teammate "$r" "Sam (payments)" "Add /version endpoint" sam/version-endpoint <<'SH'
printf '\n\n@app.get("/version")\ndef version():\n    return jsonify(version=VERSION)\n' >> service/app.py
printf '\n\ndef test_version_endpoint():\n    assert client().get("/version").get_json()["version"]\n' >> service/test_app.py
SH
n=$(gh_open_pr "$r" sam/version-endpoint "Add /version endpoint" "Adds GET /version so the dashboard can show which build is running. Tests included.")
gh_state_set drill31.pr "$n"
echo "Sam's PR is #$n: $(gh_web "$r")/pull/$n"
