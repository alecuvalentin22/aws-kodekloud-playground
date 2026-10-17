#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
fail=0; bad() { c_bad "$*"; fail=1; }

jenkins_get "/job/$JOB47/api/json?tree=name" >/dev/null 2>&1 || { c_bad "the $JOB47 job is gone from Jenkins"; exit 1; }

# 1. The form people use must be the one the release bot and the runbook use.
#    (The check does NOT run the job first: a build is exactly what refreshes
#    the form, and the check must not do the candidate's fixing for them.)
names=" $(release_param_names) "
if [[ $names != *" TARGET_ENV "* || $names != *" IMAGE_TAG "* ]]; then
  c_bad "the form Jenkins offers for $JOB47 has:$names -- the release bot and the runbook send TARGET_ENV and IMAGE_TAG"
  exit 1
fi
c_ok "Jenkins offers TARGET_ENV and IMAGE_TAG for $JOB47"

# 2. What people choose must be what gets released, both ways (a job that
#    always says prod would pass the first run and fail the second).
out="$STATE/scratch/check47.console"
run_release "$out" 'TARGET_ENV=prod&IMAGE_TAG=1.4.2&DRY_RUN=true'
if [[ $JOB_RESULT == SUCCESS ]] && grep -q 'RELEASE env=prod tag=1.4.2 ' "$out"; then
  c_ok "prod + 1.4.2 releases prod, 1.4.2"
else
  bad "asked for prod / 1.4.2 and got $JOB_RESULT: $(grep -m1 'RELEASE\|Releasing\|ERROR' "$out" || echo 'no RELEASE line in the console')"
fi
run_release "$out" 'TARGET_ENV=staging&IMAGE_TAG=1.4.1&DRY_RUN=true'
if [[ $JOB_RESULT == SUCCESS ]] && grep -q 'RELEASE env=staging tag=1.4.1 ' "$out"; then
  c_ok "staging + 1.4.1 releases staging, 1.4.1"
else
  bad "asked for staging / 1.4.1 and got $JOB_RESULT: $(grep -m1 'RELEASE\|Releasing\|ERROR' "$out" || echo 'no RELEASE line in the console')"
fi

# 3. A release with no tag must stop, not turn into "latest".
run_release "$out" 'TARGET_ENV=prod&IMAGE_TAG=&DRY_RUN=true'
if [[ $JOB_RESULT == SUCCESS ]] || grep -q 'RELEASE env=.* tag=latest' "$out"; then
  bad "a release with NO tag went through ($JOB_RESULT, tag=latest). 'Nothing given' must stop the job, not pick a default for prod."
else
  c_ok "a release with no tag stops ($JOB_RESULT)"
fi
rm -f "$out"
exit $fail
