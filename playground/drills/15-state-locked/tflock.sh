# shellcheck shell=bash
# Shared by break.sh / check.sh / reset.sh of drill 15. Source it AFTER
# lib/common.sh + lib/aws.sh (and aws_env). Nothing here runs by itself.
#
# The drill owns ONE small Terraform root, $WORK/tf-lock, whose state lives in the
# lab's state bucket (the one scripts/tf-init.sh / terraform/bootstrap create) under
# its own key, with S3 native locking (use_lockfile): the lock is the object
# "<state key>.tflock" next to the state. No DynamoDB, nothing billable, and the
# only resources are terraform_data (Terraform-internal), so the root needs no
# AWS permission beyond what the lab's other stacks already use for their state.
TFDIR="$WORK/tf-lock"
TF_KEY="platform-lab/playground/lock-drill/terraform.tfstate"
LOCK_KEY="$TF_KEY.tflock"
REC="$STATE/drill15.env"          # what break.sh recorded, for check.sh
TF_REGION="${AWS_REGION:-us-east-1}"

# Bucket name: <prefix>-tfstate-<account id> (terraform/bootstrap). Try the
# default prefix first, then whatever the bootstrap module's local state says.
# TFLOCK_BUCKET overrides (used by the offline test against MinIO).
tf_bucket() {
  local b
  if [[ -n ${TFLOCK_BUCKET:-} ]]; then echo "$TFLOCK_BUCKET"; return 0; fi
  b="andrei-lab-tfstate-$(aws_account)"
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then echo "$b"; return 0; fi
  b=$(terraform -chdir="$LAB_ROOT/terraform/bootstrap" output -raw state_bucket 2>/dev/null || true)
  if [[ -n $b ]] && aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then echo "$b"; return 0; fi
  return 1
}

# 0 = object exists, 1 = not found, 2 = cannot tell (403 etc.)
tf_obj_exists() {   # tf_obj_exists BUCKET KEY
  local err
  if err=$(aws s3api head-object --bucket "$1" --key "$2" 2>&1 >/dev/null); then return 0; fi
  case $err in *"Not Found"*|*404*) return 1 ;; *) return 2 ;; esac
}

# Number of delete markers on the state key: a state object that was deleted
# (and maybe put back from an old version) leaves one behind.
tf_delete_markers() {   # tf_delete_markers BUCKET
  aws s3api list-object-versions --bucket "$1" --prefix "$TF_KEY" --output json 2>/dev/null \
    | jq -r --arg k "$TF_KEY" '[.DeleteMarkers[]? | select(.Key == $k)] | length' 2>/dev/null \
    || echo unknown
}

# Remove the drill's state and lock objects (reset, and the start of break).
tf_wipe() {   # tf_wipe BUCKET
  local k
  local rc
  for k in "$LOCK_KEY" "$TF_KEY"; do
    rc=0; tf_obj_exists "$1" "$k" || rc=$?
    # 1 = not there. 0 or 2 (cannot tell): delete; deleting a missing key is harmless.
    if (( rc != 1 )); then aws s3api delete-object --bucket "$1" --key "$k" >/dev/null; fi
  done
}

# Same ISO-8601 stamp N hours ago, on macOS (BSD date) and Linux (GNU date).
hours_ago_iso() {
  date -u -v-"$1"H +%Y-%m-%dT%H:%M:%S.000000Z 2>/dev/null \
    || date -u -d "$1 hours ago" +%Y-%m-%dT%H:%M:%S.000000Z
}
