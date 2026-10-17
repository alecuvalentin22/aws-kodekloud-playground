#!/usr/bin/env bash
# Baseline = the node role has PowerUser (what jenkins-install.sh / up-aws.sh
# attach). Skipped silently when the AWS tier is not up, so a local
# `play reset` never fails here.
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"
aws_tier_up || exit 0
aws_env
aws iam attach-role-policy --role-name "$NODE_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
