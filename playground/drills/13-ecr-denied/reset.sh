#!/usr/bin/env bash
# Baseline = the node role has PowerUser (what jenkins-install.sh / up-aws.sh
# attach) and nothing the candidate added. break.sh snapshots the role's
# policies; this puts the role back to that snapshot: PowerUser re-attached,
# any extra managed policy detached, any extra inline policy deleted.
# Without a snapshot (drill never started) only the known "make it work"
# policies are removed. Skipped silently when the AWS tier is not up, so a
# local `play reset` never fails here.
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"
aws_tier_up || exit 0
aws_env
SNAP="$STATE/drill13-node-role.baseline"
aws iam attach-role-policy --role-name "$NODE_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

attached=$(aws iam list-attached-role-policies --role-name "$NODE_ROLE" --query 'AttachedPolicies[].PolicyArn' --output text)
inline=$(aws iam list-role-policies --role-name "$NODE_ROLE" --query 'PolicyNames' --output text)
if [[ -f $SNAP ]]; then
  for a in $attached; do
    grep -qxF "A $a" "$SNAP" || aws iam detach-role-policy --role-name "$NODE_ROLE" --policy-arn "$a"
  done
  for i in $inline; do
    grep -qxF "I $i" "$SNAP" || aws iam delete-role-policy --role-name "$NODE_ROLE" --policy-name "$i"
  done
  rm -f "$SNAP"
else
  for a in $attached; do
    case $a in
      */AdministratorAccess|*/PowerUserAccess|*/AmazonEC2ContainerRegistryFullAccess)
        aws iam detach-role-policy --role-name "$NODE_ROLE" --policy-arn "$a" ;;
    esac
  done
fi
exit 0
