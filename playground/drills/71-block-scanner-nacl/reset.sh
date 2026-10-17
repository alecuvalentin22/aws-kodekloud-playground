#!/usr/bin/env bash
# Deletes what break.sh recorded in $STATE/drill71.env -- and nothing else:
# re-associates the subnet with the VPC's default NACL, deletes the custom NACL(s),
# security group(s) and subnet(s) INSIDE THE RECORDED VPC (it is the drill's own
# throwaway network), then the VPC, after confirming it carries the drill's tag.
# No record, no action: other lanes' `play reset` runs this against a state dir
# where drill 71 never started. Skipped silently without AWS credentials.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"
REC="$STATE/drill71.env"
[[ -f $REC ]] || exit 0
[[ -r $AWS_CREDS_FILE ]] || exit 0
aws_env
VPC=""; SUBNET=""; NACL=""; SG=""; DEFAULT_NACL=""
# shellcheck disable=SC1090
source "$REC"
rm -rf "$WORK/drill71"
keep() { c_warn "drill 71: $1; record kept, run reset again"; exit 0; }

if [[ $VPC == vpc-* ]]; then
  rc=0; out=$(aws ec2 describe-vpcs --vpc-ids "$VPC" --query "Vpcs[0].Tags[?Key=='platform-lab-drill'].Value | [0]" --output text 2>&1) || rc=$?
  if (( rc != 0 )) && grep -Eq 'InvalidVpcID.NotFound' <<<"$out"; then
    :   # already gone
  elif (( rc != 0 )); then
    keep "cannot read the tags of $VPC (${out:0:120})"
  elif [[ $out != 71 ]]; then
    c_warn "drill 71: $VPC does not carry platform-lab-drill=71; not touching it"
    rm -f "$REC"; exit 0
  else
    # 1. Every subnet back on the VPC's default NACL, so the custom ones can go.
    def=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" "Name=default,Values=true" \
            --query 'NetworkAcls[0].NetworkAclId' --output text 2>/dev/null)
    [[ $def == acl-* ]] || def=$DEFAULT_NACL
    for a in $(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" "Name=default,Values=false" \
                 --query 'NetworkAcls[].Associations[].NetworkAclAssociationId' --output text); do
      aws ec2 replace-network-acl-association --association-id "$a" --network-acl-id "$def" >/dev/null 2>&1 \
        || keep "could not move association $a to the default NACL $def"
    done
    # 2. Custom NACLs, non-default security groups, subnets: all in this VPC only.
    for n in $(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" "Name=default,Values=false" \
                 --query 'NetworkAcls[].NetworkAclId' --output text); do
      aws ec2 delete-network-acl --network-acl-id "$n" >/dev/null 2>&1 || keep "could not delete NACL $n"
    done
    for g in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
                 --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
      aws ec2 delete-security-group --group-id "$g" >/dev/null 2>&1 || keep "could not delete security group $g"
    done
    for s in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query 'Subnets[].SubnetId' --output text); do
      aws ec2 delete-subnet --subnet-id "$s" >/dev/null 2>&1 || keep "could not delete subnet $s"
    done
    # 3. The VPC (its default NACL, default SG and main route table go with it).
    aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || keep "could not delete $VPC"
  fi
fi
rm -f "$REC" "$STATE/drill71.sgtamper"
exit 0
