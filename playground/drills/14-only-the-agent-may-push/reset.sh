#!/usr/bin/env bash
# Removes the pentest pod. Does NOT undo an IRSA/Pod Identity setup you built:
# that is an improvement, not a break. The one exception: a service-account
# annotation that points at a role that does not exist (a design half-applied)
# would make the webhook inject credentials that fail, and every later Jenkins
# build with them -- that annotation is removed. Skipped when the AWS tier is not up.
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"
aws_tier_up || exit 0
aws_env
K delete namespace sandbox --ignore-not-found --wait=false
role=$(K -n jenkins get sa jenkins-agent -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null)
if [[ -n $role ]] && ! aws iam get-role --role-name "${role##*/}" >/dev/null 2>&1; then
  K -n jenkins annotate sa jenkins-agent eks.amazonaws.com/role-arn- >/dev/null
fi
exit 0
