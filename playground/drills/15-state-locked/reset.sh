#!/usr/bin/env bash
# Removes the drill's Terraform root and its two objects (state + lock) from the
# lab's state bucket. terraform_data has nothing outside Terraform, so there is
# nothing to destroy. Skipped silently when there are no AWS credentials, so a
# local `play reset` never fails here.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"
[[ -r $AWS_CREDS_FILE ]] || exit 0
aws_env
source "$HERE/tflock.sh"
bucket=$(tf_bucket 2>/dev/null) || exit 0     # expired credentials / no bucket: nothing to clean
tf_wipe "$bucket"
rm -rf "$TFDIR" "$REC" "$STATE/drill15.env"
exit 0
