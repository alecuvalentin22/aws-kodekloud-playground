#!/usr/bin/env bash
# Jenkins on EKS, configured as code.
#
#   ./scripts/jenkins-install.sh        # or: make jenkins
#   JENKINS_ADMIN_PASSWORD=admin ./scripts/jenkins-install.sh
#
# The password is passed at install time, never written to values.yaml: this
# is a public repository. Unset, the chart generates a random one.
#
# Everything Jenkins knows comes from ci/jenkins/values.yaml (JCasC + Job DSL)
# and ci/shared-library/. Delete the controller pod and it comes back identical;
# that property is the point.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-andrei-lab-eks}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CLUSTER}"
# shellcheck disable=SC1091
source "$HERE/versions.env"
K="kubectl --context $CLUSTER"

command -v helm >/dev/null || { echo "helm not on PATH" >&2; exit 1; }

echo "==> namespaces + agent RBAC"
$K create namespace jenkins --dry-run=client -o yaml | $K apply -f - >/dev/null
$K apply -f "$HERE/ci/jenkins/rbac.yaml" >/dev/null

echo "==> ECR repository (idempotent)"
aws ecr describe-repositories --repository-names platform-lab/demo-api >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name platform-lab/demo-api \
    --image-scanning-configuration scanOnPush=true >/dev/null
# Keep the last 10 images. An ECR repo with no lifecycle policy grows forever,
# and nobody notices until the bill or the 10,000-image limit does.
aws ecr put-lifecycle-policy --repository-name platform-lab/demo-api --lifecycle-policy-text \
  '{"rules":[{"rulePriority":1,"description":"keep last 10","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},"action":{"type":"expire"}}]}' >/dev/null

echo "==> node role may push to ECR"
# The agent pods mint an ECR token from the NODE's IAM role -- no stored
# credentials. ReadOnly is attached by default (nodes must pull); push needs
# PowerUser. Every pod on the node inherits this, which is the honest caveat;
# IRSA/Pod Identity is the production answer.
aws iam attach-role-policy --role-name "${NODE_ROLE:-eksWorkerNodeRole}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser >/dev/null 2>&1 || true

echo "==> Jenkins chart $JENKINS_CHART"
helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update jenkins >/dev/null
helm upgrade --install jenkins jenkins/jenkins \
  --kube-context "$CLUSTER" --namespace jenkins \
  --version "$JENKINS_CHART" \
  -f "$HERE/ci/jenkins/values.yaml" \
  ${JENKINS_ADMIN_PASSWORD:+--set-string controller.admin.password="$JENKINS_ADMIN_PASSWORD"} \
  --wait --timeout 15m

PW="$($K -n jenkins get secret jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)"
IP="$($K get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
cat <<EOF

  Jenkins     http://$IP:30094        admin / $PW
  demo-api    http://$IP:30095        (after the first main-branch build deploys it)

The demo-api multibranch job was created by Job DSL. It scans the repo every 5
minutes; to build now: open the job and click "Scan Multibranch Pipeline Now".
EOF
