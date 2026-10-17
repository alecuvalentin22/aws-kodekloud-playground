#!/usr/bin/env bash
# Deletes the namespace recorded in $STATE/drill66.env (platform-lab-drill66) and
# the workspace ~/platform-playground-aws/drill66 -- and nothing else. No record,
# no action: another lane's reset runs this against a state dir where drill 66
# never started. Skipped silently when the AWS tier is not up.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"
REC="$STATE/drill66.env"
[[ -f $REC ]] || exit 0
aws_tier_up || exit 0
aws_env
NS=""
# shellcheck disable=SC1090
source "$REC"
rm -rf "$WORK/drill66"
if [[ $NS == platform-lab-drill66 ]]; then
  K delete ns "$NS" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1
  if K get ns "$NS" >/dev/null 2>&1; then
    c_warn "drill 66: namespace $NS is still terminating; record kept, run reset again"; exit 0
  fi
fi
rm -f "$REC"
exit 0
