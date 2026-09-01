#!/usr/bin/env bash
# Install Argo CD and Flux side by side on the EKS cluster.
#
#   ./scripts/gitops-install.sh
#
# Both reconcile the SAME git repository into DIFFERENT namespaces, so anything
# you observe between them is a property of the controller rather than of the
# manifests.
#
#   Argo CD  ->  demo-argocd
#   Flux     ->  demo-flux
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-andrei-lab-eks}"
REGION="${REGION:-us-east-1}"
REPO="${REPO:-https://github.com/alecuvalentin22/aws-kodekloud-playground.git}"

# Its own kubeconfig. A lab context sitting next to a production one in
# ~/.kube/config is how people run a delete against the wrong cluster.
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CLUSTER}"
K="kubectl --context $CLUSTER"

# Versions come from ONE place. See versions.env for why they are pinned rather
# than floating; ./scripts/check-versions.sh reports when a pin has gone stale.
# shellcheck disable=SC1091
source "$HERE/versions.env"

echo "==> kubeconfig -> $KUBECONFIG"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --alias "$CLUSTER" >/dev/null

# ---------------------------------------------------------------------------
# This script used to patch CoreDNS here.
#
# On the Fargate-only cluster it had to: EKS ships CoreDNS annotated
# `eks.amazonaws.com/compute-type: ec2`, and on a cluster with no EC2 nodes
# those pods sat Pending forever, so cluster DNS never came up and every pod
# downstream failed to resolve anything.
#
# eks:CreateFargateProfile is now known to be denied by an organization SCP on
# this account, so the cluster runs self-managed EC2 nodes and the annotation is
# satisfied as written. The patch is gone rather than made conditional -- a
# no-op patch that "already applied" every run teaches the reader nothing.
# See drills/ and AGENTS.md section 5.
#
# What DOES need checking before installing anything is pod capacity, because
# the failure mode is not obvious: pods stay Pending with "Too many pods" while
# CPU sits at 35%.
# ---------------------------------------------------------------------------
echo "==> checking pod capacity before installing anything"
CAP="$($K get nodes -o jsonpath='{.items[*].status.allocatable.pods}')"
echo "   allocatable pods per node: $CAP"
case " $CAP " in
  *" 17 "*)
    echo >&2
    echo "REFUSING: a node reports 17 allocatable pods, which is the un-delegated" >&2
    echo "t3.medium ENI ceiling. Argo CD (7) + Flux (4) + Rollouts + ingress-nginx" >&2
    echo "+ Flagger does not fit. Rebuild with ./scripts/eks-up.sh, which enables" >&2
    echo "prefix delegation BEFORE the nodes boot." >&2
    exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Argo CD
# ---------------------------------------------------------------------------
echo "==> installing Argo CD $ARGOCD_VERSION"
$K create namespace argocd --dry-run=client -o yaml | $K apply -f - >/dev/null
# --server-side is the documented install method, not a nicety: the CRDs carry
# annotations larger than the 262144-byte client-side apply limit.
$K apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null

# The stock manifests set NO resource requests at all. On EC2 nodes that is
# worse than it sounds: a pod with no request is BestEffort, so the scheduler
# treats it as free and the kubelet evicts it first under memory pressure --
# which on a 4 GiB node running six controllers is a matter of when, not if.
echo "==> setting resource requests on Argo CD"
for d in argocd-application-controller:500m:1Gi \
         argocd-repo-server:250m:512Mi \
         argocd-server:100m:256Mi \
         argocd-redis:100m:128Mi \
         argocd-applicationset-controller:100m:256Mi; do
  name="${d%%:*}"; rest="${d#*:}"; cpu="${rest%%:*}"; mem="${rest#*:}"
  kind=deployment; [ "$name" = "argocd-application-controller" ] && kind=statefulset
  $K -n argocd patch "$kind" "$name" --type=json -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/resources\",\"value\":{\"requests\":{\"cpu\":\"$cpu\",\"memory\":\"$mem\"}}}]" >/dev/null 2>&1 || true
done

echo "==> waiting for Argo CD"
$K -n argocd rollout status deploy/argocd-server --timeout=600s
$K -n argocd rollout status deploy/argocd-repo-server --timeout=600s

# argocd-server ships as ClusterIP, so the NodePort security-group rules that
# terraform/eks opens point at nothing until this patch lands. The UI answering
# 000 on :30084 while the firewall is wide open is that, not a network problem.
# scripts/argocd-webhook.sh does the same patch; doing it here means the UI is
# reachable straight after an install, webhook or no webhook.
echo "==> exposing the Argo CD UI on NodePort 30083/30084"
$K -n argocd patch svc argocd-server -p '{"spec":{"type":"NodePort","ports":[
  {"name":"http","port":80,"targetPort":8080,"nodePort":30083},
  {"name":"https","port":443,"targetPort":8080,"nodePort":30084}]}}' >/dev/null

echo "==> bootstrapping Argo CD from git (the only manual apply)"
$K apply -f gitops/argocd/bootstrap/root-app.yaml

# ---------------------------------------------------------------------------
# Flux
# ---------------------------------------------------------------------------
echo "==> installing Flux"
if ! command -v flux >/dev/null 2>&1; then
  echo "   flux CLI not found -- install with: brew install fluxcd/tap/flux" >&2
  exit 1
fi

# `flux install` rather than `flux bootstrap`: bootstrap wants write access to
# the repo so it can commit its own manifests and manage itself from Git. This
# repo is shared with Argo CD and committed to by hand, so we install the
# controllers imperatively and point them at the repo read-only. In a
# Flux-owned repo, `flux bootstrap github` is the better choice.
flux install \
  --namespace=flux-system \
  --components=source-controller,kustomize-controller,helm-controller,notification-controller \
  --context="$CLUSTER"

echo "==> waiting for Flux"
$K -n flux-system rollout status deploy/source-controller --timeout=600s
$K -n flux-system rollout status deploy/kustomize-controller --timeout=600s

echo "==> pointing Flux at the repo"
$K apply -f gitops/flux/clusters/eks/

cat <<EOF

Both controllers are running and reconciling the same repository.

  Argo CD UI    kubectl --context $CLUSTER -n argocd port-forward svc/argocd-server 8080:443
                https://localhost:8080   (user: admin)
  password      kubectl --context $CLUSTER -n argocd get secret argocd-initial-admin-secret \\
                  -o jsonpath='{.data.password}' | base64 -d

  Flux status   flux --context $CLUSTER get kustomizations
  Argo status   kubectl --context $CLUSTER -n argocd get applications

  Side by side  kubectl --context $CLUSTER get pods -n demo-argocd -n demo-flux

Try the drift demo -- it is the whole point:
  kubectl --context $CLUSTER -n demo-argocd scale deploy/podinfo --replicas=5
  kubectl --context $CLUSTER -n demo-flux   scale deploy/podinfo --replicas=5
  watch kubectl --context $CLUSTER get deploy -A -l app.kubernetes.io/name=podinfo
EOF
