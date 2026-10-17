#!/usr/bin/env bash
# Fixed means, judged by reading the live rules (no traffic is sent):
#   the DB security group has an ingress rule for tcp 5432 whose SOURCE is the
#   NEW API security group (the one inventory.txt says is attached to the API).
# Penalties (only when otherwise fixed):
#   40  5432 reachable from 0.0.0.0/0 (or ::/0)
#   25  5432 reachable from a CIDR range wider than /32 (the VPC's 10.73.0.0/16, a /24...)
#   15  the rule that references the OLD (detached) group is still there
#   20  the DB group allows anything besides tcp 5432 (other ports, all protocols)
# AWS API calls: ec2 DescribeVpcs, DescribeSecurityGroups.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
command -v jq >/dev/null || { c_bad "jq not on PATH"; exit 1; }
REC="$STATE/drill73.env"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
VPC=""; SG_OLD=""; SG_API=""; SG_DB=""
# shellcheck disable=SC1090
source "$REC"

aws ec2 describe-vpcs --vpc-ids "$VPC" >/dev/null 2>&1 || { c_bad "the drill's VPC $VPC is gone"; exit 1; }
for g in "$SG_API" "$SG_DB"; do
  aws ec2 describe-security-groups --group-ids "$g" >/dev/null 2>&1 \
    || { c_bad "security group $g is gone: the API tier's group and the DB group must both stay"; exit 1; }
done
perms=$(aws ec2 describe-security-groups --group-ids "$SG_DB" --query 'SecurityGroups[0].IpPermissions' --output json 2>&1) \
  || { c_bad "cannot read the DB security group $SG_DB: ${perms:0:200}"; exit 1; }

# A permission "covers 5432" when it is tcp with 5432 inside the range, or all protocols.
read -r -d '' COVERS <<'JQ'
def covers: (.IpProtocol == "-1") or (.IpProtocol == "tcp" and .FromPort <= 5432 and .ToPort >= 5432);
JQ
has_ref() { jq -r --arg g "$1" "$COVERS"' [.[] | select(covers) | .UserIdGroupPairs[]? | select(.GroupId == $g)] | length' <<<"$perms"; }

new_ok=$(has_ref "$SG_API")
old_ref=$(has_ref "$SG_OLD")
fail=0
if [[ $new_ok -gt 0 ]]; then
  c_ok "the DB group allows tcp 5432 from the API's current group $SG_API"
else
  c_bad "no rule on the DB group $SG_DB allows tcp 5432 from the API's current group $SG_API (inventory.txt): the API's traffic is still dropped"
  if [[ $old_ref -gt 0 ]]; then
    c_bad "  a 5432 rule still trusts $SG_OLD, the group the API no longer uses: a group ID is an identity, and the replacement has a new one"
  fi
  wide=$(jq -r "$COVERS"' [.[] | select(covers) | .IpRanges[]?.CidrIp] | join(", ")' <<<"$perms")
  [[ -n $wide ]] && c_bad "  5432 is open to $wide, which is not the fix: the DB should trust the API's group, not an address range (and the next instance in that range would get in as well)"
  fail=1
fi
(( fail == 0 )) || exit 1

# --- penalties ---------------------------------------------------------------------
open=$(jq -r "$COVERS"' [.[] | select(covers) | (.IpRanges[]?.CidrIp, .Ipv6Ranges[]?.CidrIpv6) | select(. == "0.0.0.0/0" or . == "::/0")] | join(", ")' <<<"$perms")
wider=$(jq -r "$COVERS"' [.[] | select(covers) | .IpRanges[]?.CidrIp
          | select(. != "0.0.0.0/0" and ((split("/")[1] | tonumber) < 32))] | join(", ")' <<<"$perms")
other=$(jq -r '[.[] | select((.IpProtocol == "tcp" and .FromPort == 5432 and .ToPort == 5432) | not)
          | (if .IpProtocol == "-1" then "all traffic" else "\(.IpProtocol)/\(.FromPort)-\(.ToPort)" end)] | join(", ")' <<<"$perms")
if [[ -n $open ]]; then
  echo "PENALTY 40 Postgres is open to the internet ($open). The database must only trust the API tier, never the world."
fi
if [[ -n $wider ]]; then
  echo "PENALTY 25 5432 is also open to the range $wider. Everything in that range (every instance anyone adds later) can reach the database; reference the API's security group instead."
fi
if [[ $old_ref -gt 0 ]]; then
  echo "PENALTY 15 The rule that trusts the old group $SG_OLD is still there. Stale access: if that group is ever attached to something again, it reaches the database. Revoke it (it is also what blocked deleting the old group)."
fi
if [[ -n $other ]]; then
  echo "PENALTY 20 The DB group also allows $other. Only Postgres (tcp 5432) was asked for."
fi
exit 0
