#!/usr/bin/env bash
# A scanner is hammering the public API; security wants ONE IP blocked now,
# and a teammate already hit the wall of "there is no deny in a security group".
#
# Creates a small ISOLATED network (never the default VPC, never the EKS VPC):
#   VPC platform-lab-drill71 10.71.0.0/16, subnet "public-api" 10.71.1.0/24,
#   a custom network ACL associated with that subnet, and a security group
#   platform-lab-drill71-api (443 from 0.0.0.0/0).
# The NACL carries the baseline a working API needs:
#   inbound  100 allow tcp 443          0.0.0.0/0     (the API)
#   inbound  110 allow tcp 1024-65535   0.0.0.0/0     (return traffic: NACLs are stateless)
#   outbound 100 allow all              0.0.0.0/0     (replies to clients on their ephemeral ports)
# plus AWS's implicit last rule (32767 deny all). Nothing blocks the scanner yet.
#
# All of it is free (no instances, no ENIs, no NAT/IGW). Everything created is
# recorded in $STATE/drill71.env AS IT IS CREATED; reset.sh acts ONLY on that record.
#
# AWS API calls: sts:GetCallerIdentity, ec2 CreateVpc, CreateSubnet, CreateNetworkAcl,
# CreateNetworkAclEntry, DescribeNetworkAcls, ReplaceNetworkAclAssociation,
# CreateSecurityGroup, AuthorizeSecurityGroupIngress, CreateTags (via tag-specifications).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
command -v jq >/dev/null || die "jq not on PATH"
mkdir -p "$STATE/logs"
REC="$STATE/drill71.env"
DIR="$WORK/drill71"

# An earlier run of this drill in THIS state dir: clean it up first.
[[ -f $REC ]] && bash "$HERE/reset.sh"
[[ -f $REC ]] && die "the previous drill-71 network could not be removed (see $REC); run reset first"

TAGS() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=platform-lab-drill,Value=71}]"; }

VPC=$(aws ec2 create-vpc --cidr-block 10.71.0.0/16 \
        --tag-specifications "$(TAGS vpc platform-lab-drill71)" --query Vpc.VpcId --output text)
# From here on something exists: record it at once so reset can find it.
umask 077
printf 'VPC=%s\n' "$VPC" > "$REC"

SUBNET=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.71.1.0/24 \
           --tag-specifications "$(TAGS subnet platform-lab-drill71-public-api)" --query Subnet.SubnetId --output text)
printf 'SUBNET=%s\n' "$SUBNET" >> "$REC"

NACL=$(aws ec2 create-network-acl --vpc-id "$VPC" \
         --tag-specifications "$(TAGS network-acl platform-lab-drill71-public-api)" --query NetworkAcl.NetworkAclId --output text)
printf 'NACL=%s\n' "$NACL" >> "$REC"

aws ec2 create-network-acl-entry --network-acl-id "$NACL" --ingress --rule-number 100 \
  --protocol 6 --port-range From=443,To=443 --cidr-block 0.0.0.0/0 --rule-action allow
aws ec2 create-network-acl-entry --network-acl-id "$NACL" --ingress --rule-number 110 \
  --protocol 6 --port-range From=1024,To=65535 --cidr-block 0.0.0.0/0 --rule-action allow
aws ec2 create-network-acl-entry --network-acl-id "$NACL" --egress --rule-number 100 \
  --protocol=-1 --cidr-block 0.0.0.0/0 --rule-action allow

# Associate the subnet with the custom NACL (it starts on the VPC's default one).
ASSOC=$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$SUBNET" \
          --query "NetworkAcls[0].Associations[?SubnetId=='$SUBNET'].NetworkAclAssociationId | [0]" --output text)
DEFAULT_NACL=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" "Name=default,Values=true" \
                 --query 'NetworkAcls[0].NetworkAclId' --output text)
printf 'DEFAULT_NACL=%s\n' "$DEFAULT_NACL" >> "$REC"
aws ec2 replace-network-acl-association --association-id "$ASSOC" --network-acl-id "$NACL" >/dev/null

SG=$(aws ec2 create-security-group --group-name platform-lab-drill71-api --vpc-id "$VPC" \
       --description "drill 71: public API, 443 from anywhere" \
       --tag-specifications "$(TAGS security-group platform-lab-drill71-api)" --query GroupId --output text)
printf 'SG=%s\n' "$SG" >> "$REC"
aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
  'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description=public API}]' >/dev/null

# --- the workspace ------------------------------------------------------------
rm -rf "$DIR"; mkdir -p "$DIR"
cat > "$DIR/aws-env.sh" <<ENV
# Lab credentials into THIS shell (never into ~/.aws):   . ./aws-env.sh
set -a; . "$AWS_CREDS_FILE"; set +a
unset AWS_PROFILE
export AWS_DEFAULT_REGION=us-east-1 AWS_REGION=us-east-1
ENV
cat > "$DIR/network.txt" <<TXT
The API's network (us-east-1). Everything is tagged platform-lab-drill=71.
  VPC        $VPC     platform-lab-drill71   10.71.0.0/16
  subnet     $SUBNET  "public-api"           10.71.1.0/24
  NACL       $NACL    platform-lab-drill71-public-api  (associated with the subnet)
  SG         $SG      platform-lab-drill71-api         (the API's security group)
TXT
cat > "$DIR/api-access.log" <<'LOG'
# excerpt, last minutes, source IP first (the load balancer terminates nothing: these are the raw client IPs)
198.51.100.77 - "POST /v1/login HTTP/1.1" 401 38
198.51.100.77 - "POST /v1/login HTTP/1.1" 401 38
203.0.113.5   - "GET /v1/orders?page=1 HTTP/1.1" 200 5120   # partner Contoso
198.51.100.77 - "GET /v1/.env HTTP/1.1" 404 0
198.51.100.77 - "GET /v1/admin HTTP/1.1" 404 0
198.51.100.77 - "GET /v1/../../etc/passwd HTTP/1.1" 400 0
198.51.100.10 - "GET /v1/health HTTP/1.1" 200 15            # partner Fabrikam, same /24 as the scanner
198.51.100.77 - "POST /v1/login HTTP/1.1" 401 38
203.0.113.9   - "POST /v1/orders HTTP/1.1" 201 411           # partner Contoso
198.51.100.77 - "GET /v1/users/1 HTTP/1.1" 404 0
LOG

# Sanity: the baseline is what the drill says it is (3 custom rules + the implicit one).
n=$(aws ec2 describe-network-acls --network-acl-ids "$NACL" --query 'length(NetworkAcls[0].Entries)' --output text)
[[ $n == 5 ]] || { echo "unexpected NACL entry count: $n" >&2; exit 1; }
cur=$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$SUBNET" \
        --query 'NetworkAcls[0].NetworkAclId' --output text)
[[ $cur == "$NACL" ]] || { echo "subnet is not associated with $NACL (got $cur)" >&2; exit 1; }
exit 0
