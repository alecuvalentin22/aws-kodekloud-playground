#!/usr/bin/env bash
# A platform teammate adds a REQUIRED input to the shared workflow on main.
# Both callers follow @main, so both are red from the next run.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/github.sh"; gh_load_env
gh_as_teammate "$GH_WF" "Jordan (platform)" "python-lint: require lint-config so teams can bring their own ruleset" <<'SH'
python3 - <<'PY'
p = ".github/workflows/python-lint.yml"
s = open(p).read()
old = "\npermissions:\n  contents: read\n\njobs:"
assert old in s, "permissions block not found"
s = s.replace(old, "      lint-config:\n        description: Path to the team's flake8 config\n        type: string\n        required: true\n" + old, 1)
old = "          LINT_PATH: ${{ inputs.path }}\n"
assert old in s
s = s.replace(old, old + "          LINT_CONFIG: ${{ inputs.lint-config }}\n")
old = '--max-line-length 100 "$LINT_PATH"'
assert old in s
open(p, "w").write(s.replace(old, '--config "$LINT_CONFIG" "$LINT_PATH"'))
PY
SH
gh_state_set drill33.bad-sha "$GH_LAST_SHA"
# The callers were last run before the change; run them now (workflow_dispatch) so they show red.
gh_dispatch_ci "$GH_APP1"
gh_dispatch_ci "$GH_APP2"
