#!/usr/bin/env bash
# Back to the AWS tier's baseline: the Jenkins agent pushes AS THE NODE ROLE.
# Removes the pentest pod AND the jenkins-agent IRSA annotation, always.
#
# Why always (changed 2026-10-17, after the first live run): the baseline of the
# other AWS drills is "the agent has no identity of its own". With the annotation
# left in place, drill 13's break (detach push from the node role) breaks nothing
# -- the agent pushes as its IRSA role -- and drill 14 cannot be replayed. The
# node role's own policies are restored by up-aws.sh --reset (which play reset runs).
#
# The IAM objects a solver built (OIDC provider, role, policy) are left in place
# and listed: they cost nothing, a replay can reuse them, and the names are the
# solver's choice, so deleting by guess could hit something else.
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"
aws_tier_up || exit 0
aws_env
K delete namespace sandbox --ignore-not-found --wait=false
role=$(K -n jenkins get sa jenkins-agent -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null)
if [[ -n $role ]]; then
  K -n jenkins annotate sa jenkins-agent eks.amazonaws.com/role-arn- >/dev/null
  echo "removed the jenkins-agent IRSA annotation ($role); the role itself is left in place"
fi
issuer=$(aws eks describe-cluster --name "$EKS_CLUSTER" --query cluster.identity.oidc.issuer --output text 2>/dev/null)
if [[ -n $issuer && $issuer != None ]] && aws iam list-open-id-connect-providers --output text 2>/dev/null | grep -q "${issuer#https://}"; then
  echo "left in place: the cluster's IAM OIDC provider (${issuer#https://})"
fi
exit 0
