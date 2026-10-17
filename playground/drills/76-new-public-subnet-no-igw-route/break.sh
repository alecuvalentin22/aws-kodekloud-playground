#!/usr/bin/env bash
# A teammate adds a second public subnet for a new load balancer and forgets the
# one thing that makes a subnet public: the route table association.
#
# Creates a small ISOLATED network (never the default VPC, never the EKS VPC):
#   VPC platform-lab-drill76 10.76.0.0/16 with an internet gateway attached,
#   route table public-rt (0.0.0.0/0 -> the IGW) associated with subnet public-a
#   (10.76.1.0/24), subnet private-a (10.76.11.0/24) left on the VPC's MAIN route
#   table (local route only), and subnet public-b (10.76.2.0/24), also left on
#   the main route table: this is the break (no IGW route, no association).
#
# Free: no instances, no NAT gateways, no ENIs, no Elastic IPs. Everything created
# is recorded in $STATE/drill76.env AS IT IS CREATED; reset.sh acts ONLY on that record.
#
# AWS API calls: ec2 CreateVpc, CreateInternetGateway, AttachInternetGateway,
# CreateSubnet, CreateRouteTable, CreateRoute, AssociateRouteTable,
# DescribeRouteTables, CreateTags (via tag-specifications).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
command -v jq >/dev/null || die "jq not on PATH"
mkdir -p "$STATE/logs"
REC="$STATE/drill76.env"
DIR="$WORK/drill76"

# An earlier run of this drill in THIS state dir: clean it up first.
[[ -f $REC ]] && bash "$HERE/reset.sh"
[[ -f $REC ]] && die "the previous drill-76 network could not be removed (see $REC); run reset first"

TAGS() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=platform-lab-drill,Value=76}]"; }

VPC=$(aws ec2 create-vpc --cidr-block 10.76.0.0/16 \
        --tag-specifications "$(TAGS vpc platform-lab-drill76)" --query Vpc.VpcId --output text)
umask 077
printf 'VPC=%s\n' "$VPC" > "$REC"

IGW=$(aws ec2 create-internet-gateway \
        --tag-specifications "$(TAGS internet-gateway platform-lab-drill76)" --query InternetGateway.InternetGatewayId --output text)
printf 'IGW=%s\n' "$IGW" >> "$REC"
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"

MAIN_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=association.main,Values=true" \
            --query 'RouteTables[0].RouteTableId' --output text)
printf 'MAIN_RT=%s\n' "$MAIN_RT" >> "$REC"

PUBLIC_RT=$(aws ec2 create-route-table --vpc-id "$VPC" \
              --tag-specifications "$(TAGS route-table public-rt)" --query RouteTable.RouteTableId --output text)
printf 'PUBLIC_RT=%s\n' "$PUBLIC_RT" >> "$REC"
aws ec2 create-route --route-table-id "$PUBLIC_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null

mk_subnet() {   # name cidr -> id (recorded as $3)
  local id; id=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "$2" \
                   --tag-specifications "$(TAGS subnet "$1")" --query Subnet.SubnetId --output text)
  printf '%s=%s\n' "$3" "$id" >> "$REC"; echo "$id"
}
PUBA=$(mk_subnet public-a 10.76.1.0/24 PUBLIC_A)
ASSOC_A=$(aws ec2 associate-route-table --route-table-id "$PUBLIC_RT" --subnet-id "$PUBA" --query AssociationId --output text)
printf 'ASSOC_A=%s\n' "$ASSOC_A" >> "$REC"
PRIVA=$(mk_subnet private-a 10.76.11.0/24 PRIVATE_A)
# The teammate's subnet: created, never associated.
PUBB=$(mk_subnet public-b 10.76.2.0/24 PUBLIC_B)

# --- the workspace ------------------------------------------------------------
rm -rf "$DIR"; mkdir -p "$DIR"
cat > "$DIR/aws-env.sh" <<ENV
# Lab credentials into THIS shell (never into ~/.aws):   . ./aws-env.sh
set -a; . "$AWS_CREDS_FILE"; set +a
unset AWS_PROFILE
export AWS_DEFAULT_REGION=us-east-1 AWS_REGION=us-east-1
ENV
cat > "$DIR/inventory.txt" <<TXT
The platform's network (us-east-1). Everything is tagged platform-lab-drill=76.
  VPC             $VPC          platform-lab-drill76   10.76.0.0/16
  internet gw     $IGW          attached to the VPC
  route table     $PUBLIC_RT    "public-rt"  (0.0.0.0/0 -> the internet gateway)
  route table     $MAIN_RT      the VPC's MAIN route table (local route only)

  subnet          $PUBA   "public-a"   10.76.1.0/24    public: first load balancer, works
  subnet          $PUBB   "public-b"   10.76.2.0/24    public: NEW load balancer, unreachable
  subnet          $PRIVA  "private-a"  10.76.11.0/24   private: database tier, NAT only, never an IGW
TXT

# Sanity: the baseline is what the drill says it is.
eff() {   # subnet -> "<rtb id> <has igw default route yes|no>"
  local rt; rt=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$1" \
                   --query 'RouteTables[0].RouteTableId' --output text)
  [[ $rt == rtb-* ]] || rt=$MAIN_RT
  local n; n=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
                 --query "length(RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && starts_with(GatewayId, 'igw-')])" --output text)
  echo "$rt $n"
}
set -- $(eff "$PUBA"); [[ $1 == "$PUBLIC_RT" && $2 == 1 ]] || { echo "public-a is not public ($*)" >&2; exit 1; }
set -- $(eff "$PUBB"); [[ $1 == "$MAIN_RT"   && $2 == 0 ]] || { echo "public-b is not on the bare main table ($*)" >&2; exit 1; }
set -- $(eff "$PRIVA"); [[ $1 == "$MAIN_RT"  && $2 == 0 ]] || { echo "private-a is not on the bare main table ($*)" >&2; exit 1; }
exit 0
