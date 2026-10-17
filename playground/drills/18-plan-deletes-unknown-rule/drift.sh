# shellcheck shell=bash
# Shared by break.sh / check.sh / reset.sh of drill 18. Source AFTER lib/common.sh
# + lib/aws.sh (and aws_env). Nothing here runs by itself.
#
# The drill owns ONE small Terraform root, $WORK/tf-drift: a security group in the
# account's default VPC, state in the lab's state bucket under its own key.
# Security groups and tags are free; no instance, no ENI, nothing billable.
TFDIR="$WORK/tf-drift"
TF_KEY="platform-lab/playground/drift-drill/terraform.tfstate"
LOCK_KEY="$TF_KEY.tflock"
REC="$STATE/drill18.env"
TF_REGION="${AWS_REGION:-us-east-1}"
SG_NAME=platform-lab-drill18

drift_bucket() {
  local b="andrei-lab-tfstate-$(aws_account)"
  aws s3api head-bucket --bucket "$b" >/dev/null 2>&1 && { echo "$b"; return 0; }
  return 1
}

# Security group IDs of this drill: recorded, tagged, or named.
drift_sg_ids() {
  { [[ -n ${SG_ID:-} ]] && echo "$SG_ID"
    aws ec2 describe-security-groups --filters Name=tag:platform-lab-drill,Values=18 \
      --query 'SecurityGroups[].GroupId' --output text 2>/dev/null | tr '\t' '\n'
    aws ec2 describe-security-groups --filters Name=group-name,Values=$SG_NAME \
      --query 'SecurityGroups[].GroupId' --output text 2>/dev/null | tr '\t' '\n'
  } | grep -E '^sg-' | sort -u
}

# Config text without comments (HCL # and //).
drift_config_text() { cat "$TFDIR"/*.tf 2>/dev/null | sed -e 's/#.*$//' -e 's#//.*$##'; }

# Prints the stanzas of the config that open an ingress to the world on SSH
# (or all protocols): inline `ingress {}` blocks and rule resources.
drift_open_ssh_in_config() {
  drift_config_text | awk '
    function flush() {
      if ((stanza ~ /0\.0\.0\.0\/0/ || stanza ~ /::\/0/) &&
          (stanza ~ /from_port[ \t]*=[ \t]*22([^0-9]|$)/ || stanza ~ /protocol[ \t]*=[ \t]*"-1"/ || stanza ~ /ip_protocol[ \t]*=[ \t]*"-1"/))
        print stanza
      stanza = ""
    }
    {
      if (!depth && ($0 ~ /^[ \t]*ingress[ \t]*\{/ || $0 ~ /resource[ \t]+"aws_vpc_security_group_ingress_rule"/ || $0 ~ /resource[ \t]+"aws_security_group_rule"/)) { cap = 1 }
      if (cap) {
        stanza = stanza $0 "\n"
        n = gsub(/\{/, "{"); m = gsub(/\}/, "}")
        depth += n - m
        if (depth <= 0) { depth = 0; cap = 0; flush() }
      }
    }'
}

# Back to nothing: terraform destroy (if the root is intact), then by ID / tag /
# name, then the state objects, then the workspace and the record.
drift_cleanup() {
  local bucket sg k
  export TF_IN_AUTOMATION=1 TF_INPUT=0
  [[ -f $REC ]] && source "$REC"
  if [[ -f $TFDIR/main.tf && -d $TFDIR/.terraform ]] && command -v terraform >/dev/null; then
    ( cd "$TFDIR" && terraform destroy -auto-approve -input=false -no-color -lock-timeout=30s ) >>"${STATE}/logs/drill18-destroy.log" 2>&1
  fi
  for sg in $(drift_sg_ids); do
    aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1
  done
  bucket=$(drift_bucket 2>/dev/null) || bucket=""
  if [[ -n $bucket ]]; then
    for k in "$LOCK_KEY" "$TF_KEY"; do aws s3api delete-object --bucket "$bucket" --key "$k" >/dev/null 2>&1; done
  fi
  rm -rf "$TFDIR" "$REC"
}
