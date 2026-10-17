#!/usr/bin/env bash
# Someone changed infrastructure in the "console" during an incident; the next
# Terraform plan shows changes nobody on the team wrote.
#
# Real parts: a real Terraform root with a real S3 backend manages a real security
# group in the default VPC; the "teammate" changes are real API calls made with the
# aws CLI (the same API calls a console click makes), so CloudTrail has them.
# HONEST PART: the actor in CloudTrail is the lab's IAM user, the same identity the
# candidate uses, not a different person. Everything else is as in production.
#
# AWS API calls:
#   ec2  DescribeVpcs, CreateSecurityGroup/AuthorizeSecurityGroupIngress/CreateTags
#        (via terraform), then AuthorizeSecurityGroupIngress + CreateTags (the
#        "teammate"), DescribeSecurityGroups
#   s3   state object + .tflock in the lab's state bucket (HeadBucket, Get/Put/Delete)
# Free resources only: a security group and tags. No instances, no ENIs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
source "$HERE/drift.sh"
for t in terraform jq aws; do command -v "$t" >/dev/null || die "$t not on PATH"; done

BUCKET=$(drift_bucket) || die "cannot find the lab's state bucket (andrei-lab-tfstate-<account>). Run: make state"
mkdir -p "$STATE/logs"
LOG="$STATE/logs"
drift_cleanup                                  # leftovers from an earlier run
mkdir -p "$TFDIR"

VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
if [[ -z $VPC || $VPC == None ]]; then
  VPC=$(aws eks describe-cluster --name "$EKS_CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)
fi
[[ $VPC == vpc-* ]] || die "no default VPC and no EKS VPC to put the security group in"

# --- the Terraform root -------------------------------------------------------
cat > "$TFDIR/backend.hcl" <<HCL
bucket = "$BUCKET"
region = "$TF_REGION"
HCL
cat > "$TFDIR/aws-env.sh" <<ENV
# Lab credentials into THIS shell (never into ~/.aws):   . ./aws-env.sh
set -a; . "$AWS_CREDS_FILE"; set +a
unset AWS_PROFILE
export AWS_DEFAULT_REGION=$TF_REGION AWS_REGION=$TF_REGION
ENV
cat > "$TFDIR/README.md" <<'MD'
Security group for the partner integration (payments team). State: the lab's
state bucket (backend.hcl), locking by S3 lockfile. Credentials: `. ./aws-env.sh`.
MD

write_main() {   # write_main <with-dans-change: yes|no>
  local extra=""
  [[ $1 == yes ]] && extra='
    "cost-center" = "pay-1042"   # Dan: finance tagging audit'
  cat > "$TFDIR/main.tf" <<HCL
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "5.100.0" }
  }
  backend "s3" {
    key          = "$TF_KEY"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "$TF_REGION"
}

variable "vpc_id" {
  type    = string
  default = "$VPC"
}

# Partner integration: HTTPS from the partner's gateway, nothing else.
resource "aws_security_group" "partner" {
  name        = "$SG_NAME"
  description = "Partner integration (payments)"
  vpc_id      = var.vpc_id

  ingress {
    description = "partner gateway https"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["203.0.113.10/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                 = "$SG_NAME"
    owner                = "payments"
    environment          = "staging"
    "platform-lab-drill" = "18"$extra
  }
}

output "sg_id" {
  value = aws_security_group.partner.id
}
HCL
}

export TF_IN_AUTOMATION=1 TF_INPUT=0
cd "$TFDIR"
write_main no
terraform init -input=false -no-color -backend-config=backend.hcl >"$LOG/drill18-init.log" 2>&1 \
  || die "terraform init failed: $LOG/drill18-init.log"
terraform apply -auto-approve -input=false -no-color >"$LOG/drill18-apply1.log" 2>&1 \
  || die "baseline apply failed: $LOG/drill18-apply1.log"

lineage=$(terraform state pull | jq -r .lineage)
serial=$(terraform state pull | jq -r .serial)
SG=$(terraform output -raw sg_id)
[[ -n $lineage && $lineage != null && $SG == sg-* ]] || die "could not read the baseline state"
umask 077
cat > "$REC" <<EOF2
BUCKET=$BUCKET
LINEAGE=$lineage
SERIAL=$serial
SG_ID=$SG
VPC_ID=$VPC
EOF2

# --- Dan's change: uncommitted, in main.tf ------------------------------------
write_main yes

# --- the incident: changes made by hand ----------------------------------------
# On-call opened SSH to the world to debug from home, and retagged the owner.
aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
  'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0,Description="tmp debug INC-4471"}]' >/dev/null
aws ec2 create-tags --resources "$SG" --tags Key=owner,Value=payments-oncall

# --- is the symptom there? -----------------------------------------------------
rc=0; out=$(terraform plan -detailed-exitcode -input=false -no-color 2>&1) || rc=$?
(( rc == 2 )) || die "expected a plan with changes (exit 2), got $rc: $LOG/drill18-plan.log"
grep -q '0\.0\.0\.0/0' <<<"$out" && grep -q 'payments-oncall' <<<"$out" \
  || { echo "$out" >"$LOG/drill18-plan.log"; die "the plan does not show the SSH rule and the tag change: $LOG/drill18-plan.log"; }
echo "plan: $(grep -E '^Plan:' <<<"$out")"
