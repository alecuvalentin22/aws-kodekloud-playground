#!/usr/bin/env bash
# Fixed means: the lock is gone, a plan runs and is clean, and it is the SAME
# state as before the lock (lineage + the release's id), still in S3.
# AWS API calls: s3:HeadObject (lock), s3:ListObjectVersions (soft), and what
# `terraform plan` / `state pull` do against the S3 backend (Get/Put/DeleteObject).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
source "$HERE/tflock.sh"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
# shellcheck disable=SC1090
source "$REC"
[[ -f $TFDIR/main.tf ]] || { c_bad "$TFDIR/main.tf is gone"; exit 1; }
export TF_IN_AUTOMATION=1 TF_INPUT=0

# 0. Still the S3 backend of the lab's bucket? (Switching to a local backend
#    makes every symptom disappear and fixes nothing.)
btype=$(jq -r '.backend.type // empty' "$TFDIR/.terraform/terraform.tfstate" 2>/dev/null)
bbucket=$(jq -r '.backend.config.bucket // empty' "$TFDIR/.terraform/terraform.tfstate" 2>/dev/null)
if [[ $btype != s3 || $bbucket != "$BUCKET" ]]; then
  c_bad "the backend is no longer s3://$BUCKET (it is '${btype:-none}'). Unlocking is the fix, not moving the state"; exit 1
fi

# 1. The lock object is gone.
rc=0; tf_obj_exists "$BUCKET" "$LOCK_KEY" || rc=$?
case $rc in
  0) c_bad "the lock object s3://$BUCKET/$LOCK_KEY still exists -- the state is still locked"; exit 1 ;;
  1) c_ok "no lock on the state" ;;
  *) c_warn "cannot HEAD the lock object (403?) -- trusting the plan below" ;;
esac

# 2. A plan runs and finds nothing to do.
out=$(terraform -chdir="$TFDIR" plan -detailed-exitcode -input=false -no-color -lock-timeout=5s 2>&1); prc=$?
if grep -q 'Error acquiring the state lock' <<<"$out"; then
  c_bad "terraform plan: still 'Error acquiring the state lock'"; exit 1
fi
case $prc in
  0) c_ok "terraform plan: no changes" ;;
  2) c_bad "terraform plan has pending changes (Priya's change never landed). Read them, then apply -- or revert the config"; exit 1 ;;
  *) c_bad "terraform plan failed: $(tail -n 4 <<<"$out" | tr '\n' ' ')"; exit 1 ;;
esac

# 3. Same state: lineage, serial moved forward (or equal), release id unchanged.
cur_lineage=$(terraform -chdir="$TFDIR" state pull 2>/dev/null | jq -r .lineage 2>/dev/null)
cur_serial=$(terraform -chdir="$TFDIR" state pull 2>/dev/null | jq -r .serial 2>/dev/null)
cur_id=$(terraform -chdir="$TFDIR" output -raw release_id 2>/dev/null)
if [[ $cur_lineage != "$LINEAGE" || $cur_id != "$RELEASE_ID" ]]; then
  c_bad "the state is a different state than before the lock (lineage or release id changed): it was lost and rebuilt"
  echo "PENALTY 40 The state was deleted or replaced and the resources re-created. A lock is released, never worked around by throwing the state away."
else
  c_ok "same state: lineage $LINEAGE, release id $RELEASE_ID (serial $SERIAL -> ${cur_serial:-?})"
  now_markers=$(tf_delete_markers "$BUCKET")
  if [[ $MARKERS != unknown && $now_markers != unknown && $now_markers -gt $MARKERS ]]; then
    echo "PENALTY 20 The state object was deleted at some point (a delete marker is on it). It came back, but deleting state is how states get lost."
  fi
fi

c_ok "locked state released, and the plan is clean"
