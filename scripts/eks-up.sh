#!/usr/bin/env bash
# Build the EKS cluster in three phases, so that prefix delegation is in place
# BEFORE the first node boots.
#
#   ./scripts/eks-up.sh
#
# ---------------------------------------------------------------------------
# Why three phases and not one `terraform apply`
#
# EKS caps pods per node by ENI, not by CPU. Every pod gets a real VPC IP from
# an elastic network interface, and a t3.medium has 3 ENIs x 5 IPs, which works
# out to 17 pods -- at 35% CPU utilisation. Argo CD (7 pods) + Flux (4) + Argo
# Rollouts + ingress-nginx + Flagger + Prometheus does not fit in three nodes.
#
# The fix is ENABLE_PREFIX_DELEGATION on the aws-node daemonset: the CNI then
# allocates /28 prefixes instead of single addresses and the real ceiling goes
# to 110. But TWO things have to agree, and only one of them is the daemonset:
#
#   1. the CNI must hand out prefixes        -> ENABLE_PREFIX_DELEGATION=true
#   2. kubelet must advertise the new number -> --max-pods, in the nodeadm config
#
# kubelet reads max-pods ONCE, at bootstrap. So flipping the daemonset env on a
# running cluster changes nothing for nodes that already joined -- verified the
# hard way: they kept reporting 17 afterwards. The daemonset has to be patched
# while the autoscaling group is still at zero.
#
# Hence: cluster -> patch CNI -> scale nodes.
#
# On the playground this is not a tuning exercise, it is the only option. An SCP
# explicitly denies ec2:RunInstances for every instance type except t3.medium,
# so "use a bigger node" is refused above account IAM.
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE/terraform/eks"

DESIRED="${NODE_DESIRED:-3}"
MAXPODS="${NODE_MAX_PODS:-110}"

# A DEDICATED kubeconfig, matching every other script here.
#
# Without this, `aws eks update-kubeconfig` below writes into ~/.kube/config --
# which on this laptop sits next to production contexts. A lab context beside a
# production one in a single file is how a delete lands on the wrong cluster,
# and it is the one mistake this repo says out loud that it will not make.
CLUSTER_NAME="${CLUSTER:-andrei-lab-eks}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CLUSTER_NAME}"

command -v terraform >/dev/null || { echo "terraform not on PATH" >&2; exit 1; }
command -v kubectl   >/dev/null || { echo "kubectl not on PATH" >&2; exit 1; }

echo "==> Phase 1/3: control plane, autoscaling group at zero"
terraform apply -auto-approve \
  -var node_desired_size=0 \
  -var node_min_size=0 \
  -var "node_max_pods=$MAXPODS"

CLUSTER="$(terraform output -raw cluster_name)"
REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"
# --alias so the context is named, not the full ARN; gitops-install.sh addresses
# it as `kubectl --context "$CLUSTER"`.
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --alias "$CLUSTER"
echo "    kubeconfig -> $KUBECONFIG (context $CLUSTER)"

echo
echo "==> Phase 2/3: prefix delegation, before any node exists"
# WAIT FOR THE DAEMONSET TO EXIST, do not assume it.
#
# EKS installs vpc-cni as a default component shortly AFTER CreateCluster
# returns, so there is a window in which the cluster is ACTIVE and aws-node does
# not exist yet. `rollout status` does not wait through that -- it exits
# immediately with "daemonsets.apps \"aws-node\" not found", which with
# `set -e` kills the build at the one step that cannot be redone later.
echo "    waiting for the vpc-cni daemonset to appear..."
for _ in $(seq 1 60); do
  kubectl -n kube-system get daemonset aws-node >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n kube-system get daemonset aws-node >/dev/null 2>&1 || {
  echo "aws-node never appeared -- refusing to launch nodes without prefix delegation" >&2
  exit 1
}
kubectl -n kube-system set env daemonset aws-node \
  ENABLE_PREFIX_DELEGATION=true \
  WARM_PREFIX_TARGET=1

# The daemonset has zero pods right now (no nodes), so `rollout status` returns
# immediately. Assert on the spec instead -- that is what a joining node reads.
kubectl -n kube-system get daemonset aws-node \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ENABLE_PREFIX_DELEGATION")].value}' \
  | grep -qx true \
  || { echo "ENABLE_PREFIX_DELEGATION did not stick -- refusing to launch nodes" >&2; exit 1; }
echo "    ENABLE_PREFIX_DELEGATION=true confirmed on the daemonset spec"

echo
echo "==> Phase 3/3: $DESIRED nodes, joining with max-pods=$MAXPODS"
terraform apply -auto-approve \
  -var "node_desired_size=$DESIRED" \
  -var node_min_size=1 \
  -var "node_max_pods=$MAXPODS"

echo "    waiting for nodes to register..."
for _ in $(seq 1 60); do
  n=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)
  [[ "$n" -ge "$DESIRED" ]] && break
  sleep 10
done

echo
echo "==> Result"
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.conditions[-1].type,INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type,MAX_PODS:.status.allocatable.pods'
echo
echo "If MAX_PODS reads 17, phase 2 did not take effect before the node booted."
echo "Do not try to fix it in place -- terminate the instance and let the ASG"
echo "replace it, so the new kubelet bootstraps with the right number."
