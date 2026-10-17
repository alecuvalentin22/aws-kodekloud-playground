#!/usr/bin/env bash
# Fixed means:
#   1. no ingress from 0.0.0.0/0 (or ::/0) on port 22 on the security group (live),
#   2. the legitimate 443 rule is still there (live),
#   3. Dan's cost-center tag is on the security group (live),
#   4. terraform plan -detailed-exitcode says exit 0 (config, state and reality agree),
#   5. it is the SAME state and the SAME security group (not destroyed and re-created,
#      not a new state), still on the lab's S3 backend.
# Penalties (only count when everything above passes):
#   40  the world-open SSH rule was written into the Terraform code
#   25  lifecycle ignore_changes in the code
#   40  the state was thrown away / the group re-created
# AWS API calls: ec2 DescribeSecurityGroups (read), and what terraform plan / state
# pull do against the S3 backend (Get/Put/DeleteObject on state and lock).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
source "$HERE/drift.sh"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
# shellcheck disable=SC1090
source "$REC"
[[ -f $TFDIR/main.tf ]] || { c_bad "$TFDIR/main.tf is gone"; exit 1; }
export TF_IN_AUTOMATION=1 TF_INPUT=0
bad=0; pen=()

# 0. Still the S3 backend of the lab's bucket?
btype=$(jq -r '.backend.type // empty' "$TFDIR/.terraform/terraform.tfstate" 2>/dev/null)
bbucket=$(jq -r '.backend.config.bucket // empty' "$TFDIR/.terraform/terraform.tfstate" 2>/dev/null)
if [[ $btype != s3 || $bbucket != "$BUCKET" ]]; then
  c_bad "the backend is no longer s3://$BUCKET (it is '${btype:-none}'). Moving the state is not the fix"; exit 1
fi

# 1-3. Live security group.
sgjson=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --output json 2>/dev/null | jq '.SecurityGroups[0]' 2>/dev/null)
if [[ -z $sgjson || $sgjson == null ]]; then
  c_bad "security group $SG_ID does not exist any more (destroyed or replaced)"; exit 1
fi
open=$(jq -r '[.IpPermissions[]
  | select(any(.IpRanges[]?; .CidrIp=="0.0.0.0/0") or any(.Ipv6Ranges[]?; .CidrIpv6=="::/0"))
  | select(.IpProtocol=="-1" or ((.FromPort // -1) <= 22 and (.ToPort // -1) >= 22))] | length' <<<"$sgjson")
if [[ $open != 0 ]]; then
  c_bad "$SG_ID still allows SSH (22/tcp) from 0.0.0.0/0. Somebody opened it by hand, and nobody asked for it"; bad=1
else
  c_ok "no world-open SSH rule on $SG_ID"
fi
has443=$(jq -r '[.IpPermissions[] | select(.FromPort==443 and .ToPort==443 and any(.IpRanges[]?; .CidrIp=="203.0.113.10/32"))] | length' <<<"$sgjson")
if [[ $has443 == 0 ]]; then c_bad "the partner's 443 rule (203.0.113.10/32) is gone"; bad=1; else c_ok "partner 443 rule intact"; fi
cc=$(jq -r '[.Tags[]? | select(.Key=="cost-center") | .Value] | first // empty' <<<"$sgjson")
if [[ -z $cc ]]; then c_bad "Dan's cost-center tag is not on $SG_ID yet"; bad=1; else c_ok "cost-center tag applied ($cc)"; fi

# 4. A plan that finds nothing to do.
out=$(terraform -chdir="$TFDIR" plan -detailed-exitcode -input=false -no-color -lock-timeout=5s 2>&1); prc=$?
case $prc in
  0) c_ok "terraform plan: no changes" ;;
  2) c_bad "terraform plan still has changes: config and reality disagree"; bad=1 ;;
  *) c_bad "terraform plan failed: $(tail -n 4 <<<"$out" | tr '\n' ' ')"; bad=1 ;;
esac

# 5. Same state, same group.
cur_lineage=$(terraform -chdir="$TFDIR" state pull 2>/dev/null | jq -r .lineage 2>/dev/null)
cur_sg=$(terraform -chdir="$TFDIR" output -raw sg_id 2>/dev/null)
if [[ $cur_lineage != "$LINEAGE" || $cur_sg != "$SG_ID" ]]; then
  c_bad "not the same state / security group as before (lineage or group id changed): it was destroyed and rebuilt"
  pen+=("PENALTY 40 The state or the security group was thrown away and re-created. Drift is fixed in place; re-creating drops whatever depends on the group.")
else
  c_ok "same state (lineage $LINEAGE) and same group $SG_ID"
fi

# Code review of the end state: what did the candidate write into the config?
if [[ -n $(drift_open_ssh_in_config) ]]; then
  c_bad "the config contains an ingress rule open to the world: that makes the hole permanent"
  bad=1
  pen+=("PENALTY 40 The world-open SSH rule was written into the Terraform code. A clean plan is not the goal; removing the hole is.")
fi
if drift_config_text | grep -Eq 'ignore_changes'; then
  c_warn "lifecycle ignore_changes in the config: the drift is hidden, not resolved"
  pen+=("PENALTY 25 ignore_changes hides drift instead of resolving it. The next out-of-band change in that place will be invisible too.")
fi

if (( bad )); then echo; c_dim "  (penalties are only counted once the check passes)"; exit 1; fi
(( ${#pen[@]} )) && printf '%s\n' "${pen[@]}"
c_ok "drift resolved: the hole is closed, Dan's change is applied, the plan is clean"
exit 0
