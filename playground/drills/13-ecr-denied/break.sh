#!/usr/bin/env bash
# The cloud team's "tidy-up": the node role loses ECR push. drills/18 section 2
# was reproduced exactly this way.
#
# API calls: iam:ListAttachedRolePolicies, iam:ListRolePolicies (read),
#            iam:DetachRolePolicy on eksWorkerNodeRole (the one write; proven on
#            the previous account, NOT yet on this one), then the usual Gitea push.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"; load_creds
PU=arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
RO=arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
SNAP="$STATE/drill13-node-role.baseline"

attached=$(aws iam list-attached-role-policies --role-name "$NODE_ROLE" --query 'AttachedPolicies[].PolicyArn' --output text)
inline=$(aws iam list-role-policies --role-name "$NODE_ROLE" --query 'PolicyNames' --output text)
# Baseline must hold, or the drill would break more than push: without ReadOnly
# the nodes could not PULL either (PowerUser is what carries pull here).
grep -Fqw "$PU" <<<"$attached" || die "$NODE_ROLE does not have PowerUser: nothing to detach. Run playground/setup/up-aws.sh (or play reset) first."
grep -Fqw "$RO" <<<"$attached" || die "$NODE_ROLE has no ECR ReadOnly: detaching PowerUser would stop image PULLS on every node. Not starting this drill."

# Remember exactly what the role looked like, so reset.sh can undo whatever the
# candidate adds (an inline policy, a too-broad managed policy), not only the detach.
if [[ ! -f $SNAP ]]; then
  { for a in $attached; do echo "A $a"; done; for i in $inline; do echo "I $i"; done; } > "$SNAP"
fi

# If anything below fails after the detach, put PowerUser back: a half-started
# drill has no current.env, so `play reset` would not know to repair it.
detached=false
restore() {
  local rc=$?
  if [[ $detached == true && $rc -ne 0 ]]; then
    aws iam attach-role-policy --role-name "$NODE_ROLE" --policy-arn "$PU" >/dev/null 2>&1 || true
  fi
}
trap restore EXIT

detached=true
aws iam detach-role-policy --role-name "$NODE_ROLE" --policy-arn "$PU"
# IAM is eventually consistent; give the detach time to land before building.
sleep 20
as_teammate "Sam (payments)" payments/demo-api "api: report the owning team on /" <<'SH'
sed -i.bak 's/return jsonify(app="demo-api", version=VERSION)/return jsonify(app="demo-api", version=VERSION, team="payments")/' app.py && rm app.py.bak
grep -q 'team="payments"' app.py
SH
jenkins_scan
