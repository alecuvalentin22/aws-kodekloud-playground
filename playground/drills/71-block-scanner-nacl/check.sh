#!/usr/bin/env bash
# Fixed means, judged by evaluating the live rules (no traffic is sent):
#   the subnet still uses the drill's custom NACL, and replaying NACL evaluation
#   (rules by number, lowest first, first match wins, then the implicit deny) says
#     - the scanner 198.51.100.77 is DENIED inbound, on 443 and on any other port
#     - a normal client 203.0.113.5 is ALLOWED inbound on 443
#     - return traffic still flows: replies to the client's ephemeral port (outbound)
#       and return packets on ephemeral ports (inbound)
#   and the security group still lets the internet reach 443 (it cannot deny anyone).
# Penalties (only when otherwise fixed): the security group's 443 rule was removed
# or narrowed at some point (40); a range wider than /32 is denied (20).
# AWS API calls: ec2 DescribeNetworkAcls, DescribeSecurityGroups, DescribeVpcs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
command -v jq >/dev/null || { c_bad "jq not on PATH"; exit 1; }
REC="$STATE/drill71.env"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
VPC=""; SUBNET=""; NACL=""; SG=""
# shellcheck disable=SC1090
source "$REC"
SCANNER=198.51.100.77
CLIENT=203.0.113.5
fail=0
bad() { c_bad "$*"; fail=1; }

aws ec2 describe-vpcs --vpc-ids "$VPC" >/dev/null 2>&1 || { c_bad "the drill's VPC $VPC is gone"; exit 1; }

# --- 1. Security group: stateful, ALLOW-only. The API must stay reachable. -------
TAMPER="$STATE/drill71.sgtamper"
sg=$(aws ec2 describe-security-groups --group-ids "$SG" --output json 2>&1) \
  || { c_bad "cannot read the security group $SG: ${sg:0:200}"; exit 1; }
sg_ok=$(jq -r '[.SecurityGroups[0].IpPermissions[]
        | select((.IpProtocol=="tcp" and .FromPort<=443 and .ToPort>=443) or .IpProtocol=="-1")
        | select(any(.IpRanges[]?; .CidrIp=="0.0.0.0/0"))] | length' <<<"$sg")
if [[ $sg_ok == 0 ]]; then
  printf 'removed or narrowed\n' > "$TAMPER"
  bad "the security group $SG no longer allows tcp 443 from 0.0.0.0/0: nobody can reach the API. A security group only ALLOWS; it cannot block one address. Put the rule back"
else
  c_ok "security group still allows 443 from the internet (it cannot deny; that is the NACL's job)"
fi

# --- 2. Which NACL guards the subnet? --------------------------------------------
cur=$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$SUBNET" \
        --query 'NetworkAcls[0].NetworkAclId' --output text 2>/dev/null)
if [[ $cur != "$NACL" ]]; then
  if [[ $cur == acl-* ]]; then
    bad "subnet $SUBNET now uses $cur, not the drill's NACL $NACL: the fix belongs on the NACL that guards the subnet, not on another one"
  else
    bad "cannot tell which NACL guards subnet $SUBNET"
  fi
  exit 1
fi
c_ok "subnet $SUBNET is still guarded by $NACL"

entries=$(aws ec2 describe-network-acls --network-acl-ids "$NACL" --query 'NetworkAcls[0].Entries' --output json 2>&1) \
  || { c_bad "cannot read $NACL: ${entries:0:200}"; exit 1; }

# --- 3. Replay NACL evaluation ----------------------------------------------------
# First matching rule, lowest number first, wins; nothing matching = deny.
read -r -d '' EVAL <<'JQ'
def ip2n: split(".") | map(tonumber) | reduce .[] as $o (0; . * 256 + $o);
def incidr($ip; $c): ($c | split("/")) as $p | pow(2; 32 - ($p[1] | tonumber)) as $sz
  | (($ip | ip2n) / $sz | floor) == (($p[0] | ip2n) / $sz | floor);
def pm($proto; $port): .Protocol == "-1"
  or ((.Protocol | tonumber) == $proto and (.PortRange == null or ($port >= .PortRange.From and $port <= .PortRange.To)));
[.[] | select(.Egress == $eg and .CidrBlock != null and pm($proto; $port) and incidr($ip; .CidrBlock))]
  | sort_by(.RuleNumber) | (.[0] // {RuleAction: "deny", RuleNumber: 0}) | "\(.RuleAction) \(.RuleNumber)"
JQ
# eval_pkt EGRESS(true|false) PROTO IP PORT  -> "allow|deny RULE"
eval_pkt() { jq -r --argjson eg "$1" --argjson proto "$2" --arg ip "$3" --argjson port "$4" "$EVAL" <<<"$entries"; }
expect() {   # expect "label" allow|deny EGRESS PROTO IP PORT -> sets $got
  local label=$1 want=$2; shift 2
  got=$(eval_pkt "$@"); local act=${got% *} rule=${got#* }
  if [[ $act == "$want" ]]; then c_ok "$label: $act (rule $rule)"; return 0; fi
  bad "$label: expected $want, got $act (rule $rule)"; return 1
}

# (a) the scanner, on 443, inbound.
if ! expect "scanner $SCANNER -> :443 inbound" deny false 6 "$SCANNER" 443; then
  act=${got% *}; rule=${got#* }
  later=$(jq -r --arg ip "$SCANNER" --argjson r "$rule" '
    def ip2n: split(".") | map(tonumber) | reduce .[] as $o (0; . * 256 + $o);
    def incidr($ip; $c): ($c | split("/")) as $p | pow(2; 32 - ($p[1] | tonumber)) as $sz
      | (($ip | ip2n) / $sz | floor) == (($p[0] | ip2n) / $sz | floor);
    [.[] | select(.Egress == false and .RuleAction == "deny" and .RuleNumber != 32767 and .CidrBlock != null
        and incidr($ip; .CidrBlock) and .RuleNumber > $r) | .RuleNumber] | sort | .[0] // empty' <<<"$entries")
  if [[ -n $later ]]; then
    c_bad "  there IS a deny for the scanner (rule $later), but rule $rule allows the traffic first: NACL rules are read in number order, lowest first, and the first match wins. The deny has to be numbered below $rule"
  else
    c_bad "  no inbound deny matches $SCANNER. A security group cannot do this (allow-only); the subnet's network ACL can"
  fi
fi
# (a2) the scanner on any other port: the 1024-65535 rule must not let it through either.
expect "scanner $SCANNER -> :8443 inbound (not only 443)" deny false 6 "$SCANNER" 8443 \
  || c_bad "  the scanner still gets in on ports other than 443 (the 1024-65535 return-traffic rule lets it through): deny the address for ALL protocols and ports"
# (b) a normal client reaches the API.
expect "client $CLIENT -> :443 inbound" allow false 6 "$CLIENT" 443 || true
# (c) return traffic: replies leave to the client's ephemeral port; packets for connections we start come back inbound on ephemeral ports.
expect "reply to client $CLIENT :51000 (outbound)" allow true 6 "$CLIENT" 51000 || true
expect "return traffic from $CLIENT to :40000 (inbound, ephemeral)" allow false 6 "$CLIENT" 40000 || true

(( fail == 0 )) || exit 1

# --- penalties ---------------------------------------------------------------------
wide=$(jq -r --arg ip "$SCANNER" '
  def ip2n: split(".") | map(tonumber) | reduce .[] as $o (0; . * 256 + $o);
  def incidr($ip; $c): ($c | split("/")) as $p | pow(2; 32 - ($p[1] | tonumber)) as $sz
    | (($ip | ip2n) / $sz | floor) == (($p[0] | ip2n) / $sz | floor);
  [.[] | select(.Egress == false and .RuleAction == "deny" and .RuleNumber != 32767 and .CidrBlock != null
      and (.CidrBlock | split("/")[1] | tonumber) < 32 and incidr($ip; .CidrBlock)) | .CidrBlock] | join(",")' <<<"$entries")
if [[ -n $wide ]]; then
  echo "PENALTY 20 The deny covers $wide, not just the scanner's /32. Everyone else in that range (partners, other customers) is blocked too; the ticket said not to take anyone else down."
fi
if [[ -f $TAMPER ]]; then
  echo "PENALTY 40 The security group's 443 rule was removed or narrowed on the way. A security group cannot deny one address; emptying it takes the whole API down."
fi
exit 0
