#!/usr/bin/env bash
# Removes the pentest pod. Does NOT undo an IRSA/Pod Identity setup you built:
# that is an improvement, not a break. Skipped when the AWS tier is not up.
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"
aws_tier_up || exit 0
K delete namespace sandbox --ignore-not-found --wait=false
