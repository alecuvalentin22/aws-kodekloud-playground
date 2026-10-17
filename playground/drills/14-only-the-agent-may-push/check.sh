#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"; load_creds
SA_ROLE=$(K -n jenkins get sa jenkins-agent -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null)
PIA=$(aws eks list-pod-identity-associations --cluster-name "$EKS_CLUSTER" --namespace jenkins \
        --service-account jenkins-agent --query 'associations[0].associationId' --output text 2>/dev/null)
[[ $PIA == None ]] && PIA=""
last=$(K -n sandbox logs curious-intern --tail=1 2>/dev/null)

if [[ -n $SA_ROLE || -n $PIA ]]; then
  # PATH A -- delivered. The agent has its own identity; prove the rest.
  c_ok "jenkins-agent has its own AWS identity: ${SA_ROLE:-pod identity $PIA}"
  attached=$(aws iam list-attached-role-policies --role-name "$NODE_ROLE" --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null)
  inline=$(aws iam list-role-policies --role-name "$NODE_ROLE" --query 'PolicyNames' --output text 2>/dev/null)
  if grep -Eqw 'AmazonEC2ContainerRegistryPowerUser|AmazonEC2ContainerRegistryFullAccess|PowerUserAccess|AdministratorAccess' <<<"$attached"; then
    c_bad "the node role can still push ($attached) -- every pod still can"; exit 1
  fi
  [[ -n $inline ]] && c_warn "node role has inline policies ($inline): make sure none of them push"
  c_ok "node role no longer carries push"
  [[ $last == *"ECR token minted"* ]] && c_warn "sandbox pod's last line still says it minted a token (pull-only token is fine; push is what matters)"
  assert_main_green_since "$DRILL_STARTED" || { c_bad "and the pipeline must still push"; exit 1; }
  exit 0
fi

# PATH B -- refused by the account. Verify the evidence and the design.
f="$WORK/evidence/14-design.md"
[[ -s $f ]] || { c_bad "no IRSA/Pod Identity in place, and no $f"; exit 1; }
fail=0
if grep -Eq 'not authorized to perform: (iam:CreateOpenIDConnectProvider|eks:CreatePodIdentityAssociation|eks:CreateAddon)' "$f"; then
  c_ok "evidence: a verbatim AccessDenied naming the action"
else c_bad "no verbatim 'not authorized to perform: <action>' line in $f"; fail=1; fi
issuer=$(aws eks describe-cluster --name "$EKS_CLUSTER" --query cluster.identity.oidc.issuer --output text 2>/dev/null)
if aws iam list-open-id-connect-providers --output text 2>/dev/null | grep -q "${issuer##*/}"; then
  c_bad "an OIDC provider for this cluster DOES exist -- IRSA is possible here, so build it (path A)"; fail=1
fi
grep -q 'system:serviceaccount:jenkins:jenkins-agent' "$f" \
  && c_ok "design scopes trust to the jenkins-agent service account" \
  || { c_bad "design does not pin trust to system:serviceaccount:jenkins:jenkins-agent"; fail=1; }
grep -Eq 'sts\.amazonaws\.com|pods\.eks\.amazonaws\.com' "$f" \
  && c_ok "design names the audience / service principal" \
  || { c_bad "design names neither sts.amazonaws.com (IRSA aud) nor pods.eks.amazonaws.com (Pod Identity)"; fail=1; }
grep -Eq 'arn:aws:ecr:[a-z0-9-]+:[0-9]{12}:repository/platform-lab/demo-api' "$f" \
  && c_ok "push scoped to the one repository ARN" \
  || { c_bad "push is not scoped to arn:aws:ecr:<region>:<acct>:repository/platform-lab/demo-api"; fail=1; }
grep -qi 'node role' "$f" && grep -Eqi 'remove|detach|pull.only|read.only' "$f" \
  && c_ok "design takes push away from the node role" \
  || { c_bad "design does not say what happens to the node role's push"; fail=1; }
(( fail )) && exit 1
echo "PENALTY 10 Documented, not delivered: the account refused it. Fair -- but an evidence check is weaker than a working one, so it scores lower."
