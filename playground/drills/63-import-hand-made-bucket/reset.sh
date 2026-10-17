#!/usr/bin/env bash
# Acts ONLY on what break.sh recorded in $STATE/drill63.env (no record: does
# nothing): empties (every version) and deletes the recorded bucket, removes every
# object version under the drill's prefix in the lab's state bucket, removes the
# Terraform root. Skipped silently without AWS credentials so a local `play reset`
# never fails here.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"
source "$HERE/tfimport.sh"
[[ -f $REC ]] || exit 0
[[ -r $AWS_CREDS_FILE ]] || exit 0
aws_env
# shellcheck disable=SC1090
source "$REC"
rc=0
# Never delete anything that is not this drill's bucket, whatever the record says.
if [[ -n ${BUCKET:-} && $BUCKET == ${BUCKET_PREFIX}* ]]; then
  if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    s3_purge "$BUCKET" "" && aws s3api delete-bucket --bucket "$BUCKET" || rc=1
  fi
fi
if [[ -n ${STATE_BUCKET:-} && ${TF_PREFIX:-} == platform-lab/playground/import-drill/ ]]; then
  s3_purge "$STATE_BUCKET" "$TF_PREFIX" || rc=1
fi
[[ ${TFDIR:-} == */tf-import ]] && rm -rf "$TFDIR"
rm -f "$STATE/.purge.json"
(( rc == 0 )) && rm -f "$REC"
exit $rc
