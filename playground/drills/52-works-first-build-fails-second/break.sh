#!/usr/bin/env bash
# billing/invoice-gen builds on the static agent (the PDF renderer licence is
# tied to build-01). Build #1 is green and leaves vendor/ and dist/ in the
# workspace. Then Priya bumps a library and removes a template. Build #2 trusts
# the leftover vendor/ and fails; and once that is fixed by hand, the leftover
# dist/ would still ship the removed template.
#
# Everything this creates is removed by reset.sh (job, repo, clone, agent).
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
ORG=billing REPO=invoice-gen JOB=invoice-gen
STATE_FILE="$STATE/drill52.state"

bash "$(dirname "$0")/reset.sh"        # a clean slate, whatever a failed earlier run left
agent_for_drill

repo_seed "$ORG" "$REPO" "$(dirname "$0")/repo" "invoice-gen: fetch deps, test, package" "Priya (billing)"
job_scm "$JOB" "$ORG/$REPO" "Renders and packages invoices on build-01 (label static). Drill 52; removed by play reset."

# --- build #1: green, on static-01 -----------------------------------------------------
build_run "$JOB" 150; n=$BUILD_N
[[ $BUILD_RESULT == SUCCESS ]] || die "the baseline invoice-gen build did not go green: $JENKINS_URL/job/$JOB/$n/console"
build_console "$JOB" "$n" | grep -q "Running on $AGENT_NODE" || die "baseline build did not run on $AGENT_NODE"
printf 'JOB=%s\nBASE_BUILD=%s\n' "$JOB" "$n" > "$STATE_FILE"

# --- Priya's change ----------------------------------------------------------------------
as_teammate "Priya (billing)" "$ORG/$REPO" "money-lib 2.0.0 (half-cent rounding); drop legacy template (leaks internal host)" <<'SH'
sed -i.bak 's/^money-lib=.*/money-lib=2.0.0/' deps.lock && rm -f deps.lock.bak
git rm -q templates/legacy.tmpl
grep -q '^money-lib=2.0.0' deps.lock
SH
repo_clone_for_player "$ORG" "$REPO"

# --- build #2: red ------------------------------------------------------------------------
build_run "$JOB" 150; n=$BUILD_N; res=$BUILD_RESULT
[[ $res == FAILURE ]] || die "build #2 should have failed on the stale vendor/ (got $res)"
