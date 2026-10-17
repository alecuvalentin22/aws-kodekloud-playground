#!/usr/bin/env bash
# Deletes what break.sh recorded in $STATE/drill73.env -- and nothing else:
# revokes the ingress rules of the security groups INSIDE THE RECORDED VPC
# (references first), deletes those groups, then the VPC, after confirming it
# carries the drill's tag. No record, no action: other lanes' `play reset`
# runs this against a state dir where drill 73 never started. Skipped silently
# without AWS credentials.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"
REC="$STATE/drill73.env"
[[ -f $REC ]] || exit 0
[[ -r $AWS_CREDS_FILE ]] || exit 0
aws_env
VPC=""; SG_OLD=""; SG_API=""; SG_DB=""
# shellcheck disable=SC1090
source "$REC"
rm -rf "$WORK/drill73"
keep() { c_warn "drill 73: $1; record kept, run reset again"; exit 0; }

if [[ $VPC == vpc-* ]]; then
  rc=0; out=$(aws ec2 describe-vpcs --vpc-ids "$VPC" --query "Vpcs[0].Tags[?Key=='platform-lab-drill'].Value | [0]" --output text 2>&1) || rc=$?
  if (( rc != 0 )) && grep -Eq 'InvalidVpcID.NotFound' <<<"$out"; then
    :   # already gone
  elif (( rc != 0 )); then
    keep "cannot read the tags of $VPC (${out:0:120})"
  elif [[ $out != 73 ]]; then
    c_warn "drill 73: $VPC does not carry platform-lab-drill=73; not touching it"
    rm -f "$REC"; exit 0
  else
    sgs=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
            --query "SecurityGroups[?GroupName!='default'].GroupId" --output text) || keep "cannot list security groups of $VPC"
    # 1. Revoke every ingress rule first: a group that another group's rule
    #    references cannot be deleted (DependencyViolation).
    for g in $sgs; do
      perms=$(aws ec2 describe-security-groups --group-ids "$g" --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
      if [[ -n $perms && $perms != "[]" && $perms != null ]]; then
        aws ec2 revoke-security-group-ingress --group-id "$g" --ip-permissions "$perms" >/dev/null 2>&1 \
          || c_warn "drill 73: could not revoke the rules of $g (trying to delete anyway)"
      fi
    done
    # 2. Delete the groups, in this VPC only.
    for g in $sgs; do
      aws ec2 delete-security-group --group-id "$g" >/dev/null 2>&1 || keep "could not delete security group $g"
    done
    # 3. The VPC (its default NACL, default SG and main route table go with it).
    aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || keep "could not delete $VPC"
  fi
fi
rm -f "$REC"
exit 0
