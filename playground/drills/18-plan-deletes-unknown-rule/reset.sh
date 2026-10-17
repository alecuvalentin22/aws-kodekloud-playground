#!/usr/bin/env bash
# Removes everything drill 18 made: terraform destroy (when the root is intact),
# then any security group found by the recorded ID, the tag platform-lab-drill=18
# or the name; the drill's state + lock objects in the lab's state bucket; the
# workspace and the record. Skipped silently when there are no AWS credentials or
# they have expired, so a reset never fails here.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"
[[ -r $AWS_CREDS_FILE ]] || exit 0
aws_env
source "$HERE/drift.sh"
aws sts get-caller-identity >/dev/null 2>&1 || exit 0
mkdir -p "$STATE/logs"
drift_cleanup
exit 0
