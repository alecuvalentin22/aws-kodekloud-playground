#!/usr/bin/env bash
# The API cannot reach its database since a security group "cleanup".
#
# Creates a small ISOLATED network (never the default VPC, never the EKS VPC):
#   VPC platform-lab-drill73 10.73.0.0/16 and three security groups
#     platform-lab-drill73-api-old  the API tier's OLD group (replaced, supposed to be deleted)
#     platform-lab-drill73-api      the NEW group the API tier uses now
#     platform-lab-drill73-db       the database tier: 5432/tcp from the group api-old
# Then it plays the cleanup: it tries to DELETE api-old. AWS refuses
# (DependencyViolation) because the DB group's rule still references it; the
# real error is written to the workspace's cleanup.log. So the old group stays,
# detached (nothing uses it), and the DB rule still trusts it. There are no
# instances, so which group "the API uses" is stated in inventory.txt.
#
# All of it is free (security groups and a VPC; no instances, no ENIs, no NAT/IGW).
# Everything created is recorded in $STATE/drill73.env AS IT IS CREATED;
# reset.sh acts ONLY on that record.
#
# AWS API calls: sts:GetCallerIdentity, ec2 CreateVpc, CreateSecurityGroup,
# AuthorizeSecurityGroupIngress, DeleteSecurityGroup (expected to be refused),
# CreateTags (via tag-specifications).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
command -v jq >/dev/null || die "jq not on PATH"
mkdir -p "$STATE/logs"
REC="$STATE/drill73.env"
DIR="$WORK/drill73"

# An earlier run of this drill in THIS state dir: clean it up first.
[[ -f $REC ]] && bash "$HERE/reset.sh"
[[ -f $REC ]] && die "the previous drill-73 network could not be removed (see $REC); run reset first"

TAGS() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=platform-lab-drill,Value=73}]"; }

VPC=$(aws ec2 create-vpc --cidr-block 10.73.0.0/16 \
        --tag-specifications "$(TAGS vpc platform-lab-drill73)" --query Vpc.VpcId --output text)
# From here on something exists: record it at once so reset can find it.
umask 077
printf 'VPC=%s\n' "$VPC" > "$REC"

mksg() {   # name description -> id
  aws ec2 create-security-group --group-name "platform-lab-drill73-$1" --vpc-id "$VPC" --description "$2" \
    --tag-specifications "$(TAGS security-group "platform-lab-drill73-$1")" --query GroupId --output text
}
SG_OLD=$(mksg api-old "drill 73: the API tier OLD group (replaced)")
printf 'SG_OLD=%s\n' "$SG_OLD" >> "$REC"
SG_API=$(mksg api "drill 73: the API tier group (current)")
printf 'SG_API=%s\n' "$SG_API" >> "$REC"
SG_DB=$(mksg db "drill 73: the database tier")
printf 'SG_DB=%s\n' "$SG_DB" >> "$REC"

# The DB trusts "members of the old API group", by group ID.
aws ec2 authorize-security-group-ingress --group-id "$SG_DB" --ip-permissions \
  "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$SG_OLD,Description=postgres from the API}]" >/dev/null

# --- the "cleanup": delete the old group. AWS refuses while the DB rule references it. ---
rm -rf "$DIR"; mkdir -p "$DIR"
set +e
del=$(aws ec2 delete-security-group --group-id "$SG_OLD" 2>&1); rc=$?
set -e
(( rc != 0 )) && grep -q DependencyViolation <<<"$del" \
  || { echo "expected DeleteSecurityGroup on $SG_OLD to be refused with DependencyViolation (rc=$rc): ${del:0:200}" >&2; exit 1; }
{
  echo "# security group cleanup, step 4 of 4: remove the old API tier group"
  echo "\$ aws ec2 delete-security-group --group-id $SG_OLD"
  echo "$del"
  echo "# (I stopped here and left it; the API team pinged me about timeouts)"
} > "$DIR/cleanup.log"

# --- the workspace ------------------------------------------------------------
cat > "$DIR/aws-env.sh" <<ENV
# Lab credentials into THIS shell (never into ~/.aws):   . ./aws-env.sh
set -a; . "$AWS_CREDS_FILE"; set +a
unset AWS_PROFILE
export AWS_DEFAULT_REGION=us-east-1 AWS_REGION=us-east-1
ENV
cat > "$DIR/inventory.txt" <<TXT
Orders platform network (us-east-1). Everything is tagged platform-lab-drill=73.
There are no instances in this lab: this file says what is attached to what.
  VPC   $VPC     platform-lab-drill73   10.73.0.0/16
  SG    $SG_API  platform-lab-drill73-api      ATTACHED to the API tier (since this morning)
  SG    $SG_OLD  platform-lab-drill73-api-old  DETACHED, replaced by the one above, nothing uses it
  SG    $SG_DB   platform-lab-drill73-db       ATTACHED to the database tier (Postgres, 5432/tcp)
TXT
cat > "$DIR/api-errors.log" <<'LOG'
# excerpt from the orders API, last minutes
ERROR orders-api db: dial tcp 10.73.2.15:5432: i/o timeout (after 30s)
ERROR orders-api db: dial tcp 10.73.2.15:5432: i/o timeout (after 30s)
WARN  orders-api healthcheck: database unreachable, readiness=false
ERROR orders-api db: dial tcp 10.73.2.15:5432: i/o timeout (after 30s)
LOG

# Sanity: the DB rule is what the drill says it is.
src=$(aws ec2 describe-security-groups --group-ids "$SG_DB" \
        --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)
[[ $src == "$SG_OLD" ]] || { echo "DB rule source is $src, expected $SG_OLD" >&2; exit 1; }
exit 0
