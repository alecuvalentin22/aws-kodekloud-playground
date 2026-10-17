#!/usr/bin/env bash
# Fixed means, judged by evaluating the live route tables (no traffic is sent):
#   - the internet gateway is still attached to the VPC
#   - public-b's EFFECTIVE route table (the one it is explicitly associated with,
#     else the VPC's main table) has an active 0.0.0.0/0 -> the attached IGW route
#   - public-a is unchanged (still public)
#   - private-a's effective table has NO 0.0.0.0/0 -> internet gateway route
# Penalties (only when otherwise fixed): private-a ended up public, i.e. the IGW
# route was added to the MAIN table (40); the IGW was detached or replaced on the
# way (15).
# AWS API calls: ec2 DescribeVpcs, DescribeInternetGateways, DescribeRouteTables.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
command -v jq >/dev/null || { c_bad "jq not on PATH"; exit 1; }
REC="$STATE/drill76.env"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
VPC=""; IGW=""; MAIN_RT=""; PUBLIC_RT=""; PUBLIC_A=""; PUBLIC_B=""; PRIVATE_A=""
# shellcheck disable=SC1090
source "$REC"
TAMPER="$STATE/drill76.igwtamper"
fail=0
bad() { c_bad "$*"; fail=1; }

aws ec2 describe-vpcs --vpc-ids "$VPC" >/dev/null 2>&1 || { c_bad "the drill's VPC $VPC is gone"; exit 1; }

# --- 1. The internet gateway: attached to this VPC, and the one from the start ---
CUR_IGW=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" \
            --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)
if [[ $CUR_IGW != igw-* ]]; then
  printf 'detached\n' > "$TAMPER"
  bad "no internet gateway is attached to the VPC $VPC: no route to an IGW can carry traffic. Re-attach $IGW (aws ec2 attach-internet-gateway)"
  exit 1
fi
if [[ $CUR_IGW != "$IGW" ]]; then
  printf 'replaced\n' > "$TAMPER"
  c_ok "an internet gateway ($CUR_IGW) is attached (it replaced the original $IGW)"
else
  c_ok "internet gateway $IGW is attached to the VPC"
fi

# --- 2. Effective route table of a subnet (explicit association, else MAIN) ------
MAIN_NOW=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=association.main,Values=true" \
             --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
[[ $MAIN_NOW == rtb-* ]] || MAIN_NOW=$MAIN_RT
effective() {   # subnet -> prints "<rtb-id> <explicit|main> <default-route-target or none>"
  local sub=$1 rt how=explicit tables
  rt=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$sub" \
         --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
  [[ $rt == rtb-* ]] || { rt=$MAIN_NOW; how=main; }
  tables=$(aws ec2 describe-route-tables --route-table-ids "$rt" --output json 2>/dev/null) || { echo "$rt $how error"; return; }
  tgt=$(jq -r '[.RouteTables[0].Routes[] | select(.DestinationCidrBlock=="0.0.0.0/0")
                | select((.State // "active")=="active") | (.GatewayId // .NatGatewayId // "other")] | .[0] // "none"' <<<"$tables")
  echo "$rt $how $tgt"
}

read -r B_RT B_HOW B_TGT <<<"$(effective "$PUBLIC_B")"
read -r A_RT A_HOW A_TGT <<<"$(effective "$PUBLIC_A")"
read -r P_RT P_HOW P_TGT <<<"$(effective "$PRIVATE_A")"

# --- 3. public-b must be public ---------------------------------------------------
if [[ $B_TGT == "$CUR_IGW" ]]; then
  c_ok "public-b uses $B_RT ($B_HOW table) which sends 0.0.0.0/0 to $CUR_IGW: it is public"
else
  if [[ $B_HOW == main ]]; then
    bad "public-b ($PUBLIC_B) has no route table of its own: it silently uses the VPC's MAIN table $B_RT, whose default route is: $B_TGT. A subnet is public only if its route table sends 0.0.0.0/0 to the internet gateway"
  else
    bad "public-b is associated with $B_RT, whose 0.0.0.0/0 route goes to: $B_TGT (need the attached internet gateway $CUR_IGW)"
  fi
fi

# --- 4. public-a unchanged ---------------------------------------------------------
if [[ $A_TGT == "$CUR_IGW" ]]; then
  c_ok "public-a still public (via $A_RT)"
else
  bad "public-a lost its internet route (table $A_RT, default route: $A_TGT): it worked before, put that back"
fi

# --- 5. private-a: must not be reachable through an IGW (checked after the fix) ----
(( fail == 0 )) || exit 1
if [[ $P_TGT == igw-* ]]; then
  c_ok "(noted) private-a is routed through $P_TGT: see the penalty below"
else
  c_ok "private-a ($P_RT, $P_HOW table) has no route to an internet gateway: it stays private"
fi

# --- penalties ---------------------------------------------------------------------
if [[ $P_TGT == igw-* ]]; then
  echo "PENALTY 40 private-a (the database tier) now has 0.0.0.0/0 -> $P_TGT too (table $P_RT, $P_HOW). Adding the IGW route to the MAIN table makes EVERY subnet without an explicit association public. Associate only public-b with the public table."
fi
if [[ -f $TAMPER ]]; then
  echo "PENALTY 15 The internet gateway was detached or replaced on the way. It was fine; the missing piece was public-b's route table."
fi
exit 0
