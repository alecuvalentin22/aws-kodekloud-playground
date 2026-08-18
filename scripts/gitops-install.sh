#!/usr/bin/env bash
# Install Argo CD and Flux side by side on the EKS Fargate cluster.
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

CLUSTER="${CLUSTER:-andrei-lab-eks}"
REGION="${REGION:-us-east-1}"
REPO="${REPO:-https://github.com/alecuvalentin22/aws-kodekloud-playground.git}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.1}"

# Its own kubeconfig. A lab context sitting next to a production one in
# ~/.kube/config is how people run a delete against the wrong cluster.
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/andrei-lab-eks}"
K="kubectl --context $CLUSTER"

echo "==> kubeconfig -> $KUBECONFIG"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --alias "$CLUSTER" >/dev/null

# ---------------------------------------------------------------------------
# THE FARGATE-ONLY GOTCHA, AND IT BLOCKS EVERYTHING DOWNSTREAM.
#
# EKS ships CoreDNS annotated eks.amazonaws.com/compute-type: ec2, because it
# normally runs on nodes. On a cluster with NO nodes that annotation means the
# pods are never scheduled -- CoreDNS sits Pending forever and cluster DNS never
# works. Nothing else will come up, and the symptom (every pod failing to
# resolve anything) points nowhere near the cause.
#
# Removing the annotation lets the kube-system Fargate profile pick it up.
# ---------------------------------------------------------------------------
echo "==> patching CoreDNS for Fargate"
$K -n kube-system patch deployment coredns --type json \
  -p='[{"op":"remove","path":"/spec/template/metadata/annotations/eks.amazonaws.com~1compute-type"}]' \
  2>/dev/null && echo "   annotation removed" || echo "   already patched"
$K -n kube-system rollout restart deployment coredns >/dev/null
echo "   waiting for CoreDNS on Fargate (Fargate pods take ~60s to get a micro-VM)"
$K -n kube-system rollout status deployment coredns --timeout=600s

# ---------------------------------------------------------------------------
# Argo CD
# ---------------------------------------------------------------------------
echo "==> installing Argo CD $ARGOCD_VERSION"
$K create namespace argocd --dry-run=client -o yaml | $K apply -f - >/dev/null
# --server-side is the documented install method, not a nicety: the CRDs carry
# annotations larger than the 262144-byte client-side apply limit.
$K apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null

# The stock manifests set NO resource requests. On Fargate that means every pod
# gets the 0.25 vCPU / 0.5 GB minimum micro-VM regardless of what it needs, and
# the application-controller in particular will struggle. Set them explicitly.
echo "==> sizing Argo CD for Fargate"
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
$K -n argocd rollout status deploy/argocd-server --timeout=900s
$K -n argocd rollout status deploy/argocd-repo-server --timeout=900s

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
$K -n flux-system rollout status deploy/source-controller --timeout=900s
$K -n flux-system rollout status deploy/kustomize-controller --timeout=900s

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
