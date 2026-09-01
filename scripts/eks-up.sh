#!/usr/bin/env bash
# Build the EKS cluster in four phases: prefix delegation must be in place
# BEFORE the first node boots, and storage must work before anything with a PVC.
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
# Hence: cluster -> patch CNI -> scale nodes -> storage.
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

# ---------------------------------------------------------------------------
# PREFLIGHT: does terraform.tfvars still name YOUR public IP?
#
# The EKS API endpoint is locked to public_access_cidrs. If your address has
# rotated since the file was last edited, everything still builds -- the cluster
# reaches ACTIVE, terraform reports success -- and then every kubectl call hangs
# forever, because the API will not talk to you.
#
# Phase 2 is where that surfaces, as "waiting for the vpc-cni daemonset to
# appear" that never returns. It reads like a slow CNI and it is a firewall.
# Cost when it happened: 11 minutes of a 3-hour window, then a full rebuild.
#
# A REBUILD, because eks:UpdateClusterConfig is DENIED on this playground:
#
#   AccessDeniedException: User is not authorized to perform this action
#
# so the allowlist cannot be corrected after CreateCluster. On a normal AWS
# account you would just update it. Here the address you build with is the
# address you are stuck with, which makes checking it beforehand the whole
# difference between a 5-second fix and a 20-minute one.
# ---------------------------------------------------------------------------
TFVARS="$HERE/terraform/eks/terraform.tfvars"
if [[ -f "$TFVARS" ]]; then
  # -4 matters: curl and friends return IPv6 on some networks, and a security
  # group rule wants IPv4.
  MYIP="$(python3 -c "import urllib.request;print(urllib.request.urlopen('https://checkip.amazonaws.com').read().decode().strip())" 2>/dev/null || true)"
  # `|| true` is load-bearing. Once public_access_cidrs became /24s there was no
  # /32 to find, grep exited 1, and under `set -e` a failing command
  # substitution in an assignment kills the script -- with NO output at all,
  # because this runs before the first echo. The build simply returned 1.
  WANT="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32' "$TFVARS" | head -1 || true)"
  # Only meaningful when the allowlist is a single /32. With a wider prefix the
  # check cannot be a string compare, and the whole point of widening was that a
  # rotation inside the prefix is now survivable -- so skip it.
  if [[ -n "$MYIP" && -n "$WANT" && "$WANT" != "$MYIP/32" ]]; then
    echo >&2
    echo "REFUSING: your public IP has changed since terraform.tfvars was written." >&2
    echo "  tfvars allows : $WANT" >&2
    echo "  you are at    : $MYIP/32" >&2
    echo >&2
    echo "The cluster would build and then be unreachable, and this playground" >&2
    echo "denies eks:UpdateClusterConfig so it could not be fixed afterwards." >&2
    echo >&2
    echo "  sed -i '' 's|$WANT|$MYIP/32|' $TFVARS" >&2
    exit 1
  fi
  if [[ -n "$WANT" ]]; then
    echo "==> Preflight: public IP $MYIP matches the /32 in terraform.tfvars"
  else
    echo "==> Preflight: allowlist is wider than a /32 ($(grep -oE '"[0-9./, "]+"' "$TFVARS" | head -1)); IP is $MYIP"
  fi
fi
command -v kubectl   >/dev/null || { echo "kubectl not on PATH" >&2; exit 1; }

echo "==> Phase 1/4: control plane, autoscaling group at zero"
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
echo "==> Phase 2/4: prefix delegation, before any node exists"
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
echo "==> Phase 3/4: $DESIRED nodes, joining with max-pods=$MAXPODS"
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

# ---------------------------------------------------------------------------
# Phase 4: a StorageClass that can actually provision.
#
# EKS 1.33 ships a `gp2` StorageClass marked default whose provisioner is
# `kubernetes.io/aws-ebs` -- the IN-TREE driver, REMOVED from Kubernetes in
# 1.27. So the cluster has a default StorageClass that can never bind a PVC.
#
# The symptom points somewhere else entirely:
#
#   0/4 nodes are available: pod has unbound immediate PersistentVolumeClaims
#
# which reads as scheduling or capacity. `kubectl get sc` shows a StorageClass
# present and healthy-looking, and nothing says "this provisioner no longer
# exists". APISIX's etcd StatefulSet sat Pending on it for 20 minutes.
#
# Both halves are needed -- the driver AND a StorageClass that uses it. Doing
# this by hand twice is what put it here.
# ---------------------------------------------------------------------------
echo
echo "==> Phase 4/4: EBS CSI driver + a StorageClass that can provision"
if ! aws eks describe-addon --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver      --region "$REGION" >/dev/null 2>&1; then
  # The node role needs the policy before the driver can create volumes. Both
  # of these are permitted on this playground, which is a pleasant surprise
  # given how much of the EKS API is not.
  aws iam attach-role-policy --role-name "${NODE_ROLE:-eksWorkerNodeRole}"     --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy >/dev/null 2>&1 || true
  aws eks create-addon --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver     --region "$REGION" >/dev/null 2>&1 || true
fi
for _ in $(seq 1 40); do
  [[ "$(aws eks describe-addon --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver         --region "$REGION" --query 'addon.status' --output text 2>/dev/null)" == "ACTIVE" ]] && break
  sleep 15
done
kubectl apply -f "$HERE/kubernetes/storageclass-gp3.yaml" >/dev/null
# Demote gp2 so the dead in-tree class stops being the default.
kubectl patch sc gp2 -p   '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
echo "    default StorageClass: $(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name} ({.provisioner}){end}')"

echo
echo "==> Result"
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.conditions[-1].type,INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type,MAX_PODS:.status.allocatable.pods'
echo
echo "If MAX_PODS reads 17, phase 2 did not take effect before the node booted."
echo "Do not try to fix it in place -- terminate the instance and let the ASG"
echo "replace it, so the new kubelet bootstraps with the right number."
