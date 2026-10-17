# shellcheck shell=bash
# Helpers for drill 47 only (sourced after lib/common.sh).
JOB47=payments-release
REPO47=payments/release-job

# release_param_names -- the parameter names Jenkins currently OFFERS for the job.
release_param_names() {
  jenkins_get "/job/$JOB47/api/json?tree=property%5BparameterDefinitions%5Bname%5D%5D" 2>/dev/null \
    | jq -r '[.property[]? | .parameterDefinitions[]? | .name] | join(" ")'
}

# run_release OUTFILE 'TARGET_ENV=prod&IMAGE_TAG=1.4.2&DRY_RUN=true' [seconds]
# Build with those values, wait, save the console, leave the result in JOB_RESULT.
run_release() {
  local out=$1 q=$2 limit=${3:-90} n t0 b
  n=$(jenkins_get "/job/$JOB47/api/json?tree=nextBuildNumber" | jq -r .nextBuildNumber) || return 1
  jenkins_post "$JENKINS_URL/job/$JOB47/buildWithParameters?delay=0&$q" >/dev/null || return 1
  t0=$(date +%s); JOB_RESULT=TIMEOUT
  while (( $(date +%s) - t0 < limit )); do
    b=$(jenkins_get "/job/$JOB47/$n/api/json?tree=building,result" 2>/dev/null || true)
    if [[ -n $b && $(jq -r .building <<<"$b") == false ]]; then JOB_RESULT=$(jq -r '.result' <<<"$b"); break; fi
    sleep 2
  done
  jenkins_get "/job/$JOB47/$n/consoleText" > "$out" 2>/dev/null || : > "$out"
}
