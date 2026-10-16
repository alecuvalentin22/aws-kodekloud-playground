#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
assert_main_green_since "$DRILL_STARTED" || exit 1
probe=$(K -n demo-ci get deploy demo-api -o json | jq -r '.spec.template.spec.containers[0].readinessProbe.httpGet.path // ""')
if [[ -z $probe ]]; then
  c_bad "the readiness probe is gone -- the rollout is 'green' because nothing checks it any more"
  exit 1
fi
c_ok "readiness probe still checks $probe"
