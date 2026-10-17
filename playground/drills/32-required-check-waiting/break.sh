#!/usr/bin/env bash
# Protection requires `build`. A teammate adds a matrix, so `build` stops
# existing (it becomes `build (3.12)` / `build (3.13)`). Priya's PR waits forever.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/github.sh"; gh_load_env
r=$GH_APP1
gh_protect "$r" build
gh_as_teammate "$r" "Jordan (platform)" "ci: test on Python 3.12 and 3.13" <<'SH'
python3 - <<'PY'
p = ".github/workflows/ci.yml"
s = open(p).read()
old = "  build:\n    runs-on: ubuntu-latest\n"
assert old in s, "build job not found"
s = s.replace(old, '  build:\n    strategy:\n      matrix:\n        python: ["3.12", "3.13"]\n    runs-on: ubuntu-latest\n')
old = '          python-version: "3.13"\n'
assert s.count(old) == 1, "python-version line not found once"
open(p, "w").write(s.replace(old, "          python-version: ${{ matrix.python }}\n"))
PY
SH
gh_state_set drill32.bad-sha "$GH_LAST_SHA"
gh_as_teammate "$r" "Priya (payments)" "Document the readiness probe contract" priya/readiness-note <<'SH'
printf '\n\n# Readiness probe target for Kubernetes: keep it fast, no I/O.\n' >> service/app.py
SH
n=$(gh_open_pr "$r" priya/readiness-note "Document the readiness probe contract" "Comment only. Needs to ship today.")
gh_state_set drill32.pr "$n"
echo "Priya's PR is #$n: $(gh_web "$r")/pull/$n"
