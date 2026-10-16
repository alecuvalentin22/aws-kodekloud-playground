#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"; load_creds
assert_main_green_since "$DRILL_STARTED" || exit 1
img=$(K -n demo-ci get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ $img == *.dkr.ecr.*amazonaws.com/* ]] || { c_bad "running image $img is not from ECR"; exit 1; }
c_ok "pushed to ECR and deployed"

attached=$(aws iam list-attached-role-policies --role-name "$NODE_ROLE" --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null) \
  || { c_warn "cannot list $NODE_ROLE's policies -- penalties not assessed"; exit 0; }
for broad in AdministratorAccess PowerUserAccess AmazonEC2ContainerRegistryFullAccess; do
  grep -qw "$broad" <<<"$attached" && \
    echo "PENALTY 40 $broad on the NODE role: every pod on every node now has it. You fixed one push and widened everything."
done
inline=$(aws iam list-role-policies --role-name "$NODE_ROLE" --query 'PolicyNames' --output text 2>/dev/null || true)
if grep -qw AmazonEC2ContainerRegistryPowerUser <<<"$attached"; then
  c_ok "PowerUser is back: baseline restored"
  c_warn "still true: every pod on the node can push. Drill 14 is the structural fix."
elif [[ -n $inline ]]; then
  c_ok "push granted by an inline policy ($inline) -- if it names the one repository ARN, that is tighter than baseline"
fi
