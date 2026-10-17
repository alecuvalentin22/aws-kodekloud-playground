#!/usr/bin/env bash
# A teammate's `terraform apply` is killed while it holds the state lock.
# The lock is REAL: this runs a real apply against the S3 backend and SIGKILLs it
# while a local-exec step is running, so Terraform never gets to release the lock.
# The only thing faked is the lock's metadata (Who / Created): rewritten so it
# reads like a teammate's lock from hours ago. The lock ID is the one Terraform made.
#
# AWS API calls (all against the lab's state bucket, one key prefix):
#   s3:HeadBucket, HeadObject, GetObject, PutObject, DeleteObject, ListObjectVersions
# plus what the S3 backend itself does (GetObject/PutObject of the state and the
# .tflock object with an If-None-Match conditional write, DeleteObject on unlock).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
source "$HERE/tflock.sh"
for t in terraform jq aws; do command -v "$t" >/dev/null || die "$t not on PATH"; done

BUCKET=$(tf_bucket) || die "cannot find the lab's state bucket (andrei-lab-tfstate-<account>). Run: make state"
mkdir -p "$STATE/logs"
LOG="$STATE/logs/drill15-teammate-apply.log"

tf_wipe "$BUCKET"                       # leftovers from an earlier run
rm -rf "$TFDIR"; mkdir -p "$TFDIR"

# --- the Terraform root -------------------------------------------------------
cat > "$TFDIR/backend.hcl" <<HCL
bucket = "$BUCKET"
region = "$TF_REGION"
${TFLOCK_BACKEND_HCL_EXTRA:-}
HCL
cat > "$TFDIR/aws-env.sh" <<ENV
# Lab credentials into THIS shell (never into ~/.aws):   . ./aws-env.sh
set -a; . "$AWS_CREDS_FILE"; set +a
unset AWS_PROFILE
export AWS_DEFAULT_REGION=$TF_REGION AWS_REGION=$TF_REGION
ENV
cat > "$TFDIR/README.md" <<'MD'
Release tracker for the payments team. State: the lab's state bucket
(backend.hcl), locking by S3 lockfile. Credentials: `. ./aws-env.sh`.
MD

write_main() {   # write_main <with-migration-marker: yes|no>
  cat > "$TFDIR/main.tf" <<HCL
terraform {
  required_version = ">= 1.10"
  backend "s3" {
    key          = "$TF_KEY"
    encrypt      = true
    use_lockfile = true
  }
}

variable "settle_seconds" {
  description = "How long the post-apply smoke test waits for the release to settle."
  type        = number
  default     = 0
}

resource "terraform_data" "release" {
  input = "2026.10.1"
}

output "release_id" {
  value = terraform_data.release.id
}
HCL
  if [[ $1 == yes ]]; then
    cat >> "$TFDIR/main.tf" <<'HCL'

# Priya's change: mark the 2026.10.2 migration as done once the release exists.
resource "terraform_data" "migration_marker" {
  input      = "2026.10.2-migrated"
  depends_on = [terraform_data.release]

  provisioner "local-exec" {
    command = "sleep ${var.settle_seconds}"
  }
}
HCL
  fi
}

export TF_IN_AUTOMATION=1 TF_INPUT=0
cd "$TFDIR"
write_main no
terraform init -input=false -no-color -backend-config=backend.hcl >"$STATE/logs/drill15-init.log" 2>&1 \
  || die "terraform init failed: $STATE/logs/drill15-init.log"
terraform apply -auto-approve -input=false -no-color >"$STATE/logs/drill15-apply1.log" 2>&1 \
  || die "baseline apply failed: $STATE/logs/drill15-apply1.log"

# What check.sh compares against: proof the state is the SAME state afterwards.
lineage=$(terraform state pull | jq -r .lineage)
serial=$(terraform state pull | jq -r .serial)
release_id=$(terraform output -raw release_id)
markers=$(tf_delete_markers "$BUCKET")
[[ -n $lineage && $lineage != null && -n $release_id ]] || die "could not read the baseline state"

# --- Priya's apply: acquire the lock, start creating, get killed ---------------
write_main yes
: > "$LOG"
terraform apply -auto-approve -input=false -no-color -var settle_seconds=900 >"$LOG" 2>&1 &
apply_pid=$!

descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }

held=false
for _ in $(seq 1 45); do
  rc=0; tf_obj_exists "$BUCKET" "$LOCK_KEY" || rc=$?
  if (( rc == 0 )) && grep -q 'local-exec' "$LOG"; then held=true; break; fi
  kill -0 "$apply_pid" 2>/dev/null || break
  sleep 2
done
kids=$(descendants "$apply_pid")
kill -9 "$apply_pid" 2>/dev/null || true
# shellcheck disable=SC2086
[[ -n $kids ]] && kill -9 $kids 2>/dev/null || true
wait "$apply_pid" 2>/dev/null || true
[[ $held == true ]] || die "the teammate's apply never reached the lock + local-exec step; see $LOG"

# The lock must have survived the kill.
rc=0; tf_obj_exists "$BUCKET" "$LOCK_KEY" || rc=$?
(( rc == 0 )) || die "the lock object is gone after the kill: not a stale lock"
tmp=$(mktemp)
aws s3api get-object --bucket "$BUCKET" --key "$LOCK_KEY" "$tmp" >/dev/null
lock_id=$(jq -r .ID "$tmp")
[[ -n $lock_id && $lock_id != null ]] || die "lock object has no ID"
# Cosmetics only: who and when. ID, Operation, Version, Path stay as Terraform wrote them.
jq -c --arg who "priya@ci-runner-eu-2" --arg at "$(hours_ago_iso 3)" '.Who=$who | .Created=$at' "$tmp" > "$tmp.new"
aws s3api put-object --bucket "$BUCKET" --key "$LOCK_KEY" --body "$tmp.new" >/dev/null
rm -f "$tmp" "$tmp.new"

# main.tf on disk keeps Priya's change, settle_seconds default 0. It never reached
# the state: that is the pending change the candidate sees after unlocking.
umask 077
cat > "$REC" <<EOF2
BUCKET=$BUCKET
LINEAGE=$lineage
SERIAL=$serial
RELEASE_ID=$release_id
MARKERS=$markers
LOCK_ID=$lock_id
EOF2
