#!/usr/bin/env bash
# Deletes what break.sh recorded in $STATE/drill76.env -- and nothing else:
# disassociates and deletes the non-main route tables INSIDE THE RECORDED VPC (the
# drill's own throwaway network), detaches and deletes the recorded internet
# gateway (and any other gateway attached to that VPC), deletes the subnets, then
# the VPC, after confirming it carries the drill's tag.
# No record, no action. Skipped silently without AWS credentials.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"
REC="$STATE/drill76.env"
[[ -f $REC ]] || exit 0
[[ -r $AWS_CREDS_FILE ]] || exit 0
aws_env
VPC=""; IGW=""; MAIN_RT=""; PUBLIC_RT=""; PUBLIC_A=""; PUBLIC_B=""; PRIVATE_A=""; ASSOC_A=""
# shellcheck disable=SC1090
source "$REC"
rm -rf "$WORK/drill76"
keep() { c_warn "drill 76: $1; record kept, run reset again"; exit 0; }

igw_tag() { aws ec2 describe-internet-gateways --internet-gateway-ids "$1" \
              --query "InternetGateways[0].Tags[?Key=='platform-lab-drill'].Value | [0]" --output text 2>&1; }

if [[ $VPC == vpc-* ]]; then
  rc=0; out=$(aws ec2 describe-vpcs --vpc-ids "$VPC" --query "Vpcs[0].Tags[?Key=='platform-lab-drill'].Value | [0]" --output text 2>&1) || rc=$?
  if (( rc != 0 )) && grep -Eq 'InvalidVpcID.NotFound' <<<"$out"; then
    :   # already gone
  elif (( rc != 0 )); then
    keep "cannot read the tags of $VPC (${out:0:120})"
  elif [[ $out != 76 ]]; then
    c_warn "drill 76: $VPC does not carry platform-lab-drill=76; not touching it"
    rm -f "$REC" "$STATE/drill76.igwtamper"; exit 0
  else
    # 1. Route tables: drop every explicit association, then delete the non-main tables.
    for a in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" \
                 --query 'RouteTables[].Associations[?Main==`false`].RouteTableAssociationId' --output text); do
      aws ec2 disassociate-route-table --association-id "$a" >/dev/null 2>&1 || keep "could not disassociate $a"
    done
    for r in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" \
                 --query 'RouteTables[?length(Associations[?Main==`true`])==`0`].RouteTableId' --output text); do
      aws ec2 delete-route-table --route-table-id "$r" >/dev/null 2>&1 || keep "could not delete route table $r"
    done
    # 2. Internet gateways attached to this VPC (one per VPC at most), then the recorded one.
    for g in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" \
                 --query 'InternetGateways[].InternetGatewayId' --output text); do
      aws ec2 detach-internet-gateway --internet-gateway-id "$g" --vpc-id "$VPC" >/dev/null 2>&1 || keep "could not detach $g"
      aws ec2 delete-internet-gateway --internet-gateway-id "$g" >/dev/null 2>&1 || keep "could not delete $g"
    done
    if [[ $IGW == igw-* ]]; then
      t=$(igw_tag "$IGW") || t=gone
      if [[ $t == 76 ]]; then
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" >/dev/null 2>&1 || keep "could not delete $IGW"
      fi
    fi
    # 3. Subnets of this VPC, then the VPC (its main route table, default NACL and SG go with it).
    for s in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query 'Subnets[].SubnetId' --output text); do
      aws ec2 delete-subnet --subnet-id "$s" >/dev/null 2>&1 || keep "could not delete subnet $s"
    done
    aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || keep "could not delete $VPC"
  fi
fi
# VPC gone or never created: a recorded IGW that was created but never attached.
if [[ $IGW == igw-* ]]; then
  t=$(igw_tag "$IGW" 2>&1) || true
  if [[ $t == 76 ]]; then
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" >/dev/null 2>&1 || keep "could not delete $IGW"
  fi
fi
rm -f "$REC" "$STATE/drill76.igwtamper"
exit 0
