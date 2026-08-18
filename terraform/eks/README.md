# EKS — a managed control plane, for comparison

This is a **30-minute exercise, not the lab host.** The lab stack (Rancher,
Kong, Elasticsearch) runs on k3s/RKE2 on EC2. This module exists so there is a
real, Terraform-provisioned EKS cluster to point at and to have used.

## Why it cannot host the lab

The KodeKloud playground caps EKS at **3 pods per namespace** and
**512 MiB / 256m per pod**. Rancher alone needs more pods than that, and
Elasticsearch on Kubernetes at 512 MiB is not a thing. So: separate module,
separate state, tiny test workload.

## The playground's constraints — verified live, 2026-08-18

Three findings, all discovered by running it, and all of which contradict the
version of these notes written from documentation.

### 1. The roles do not pre-exist, and the node role has a different name

The boundary policy `AWS_EKSECSWithConditions` permits `iam:CreateRole` for a
**fixed set of names**:

```
eksClusterRole
eksWorkerNodeRole          <- NOT AmazonEKSNodeRole
AmazonEKSFargatePodExecutionRole
```

and `iam:AttachRolePolicy` only for `AmazonEKSClusterPolicy`,
`AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`,
`AmazonEC2ContainerRegistryReadOnly`, `AmazonSSMManagedInstanceCore`.

So `create_iam_roles = true` is correct here — the names just have to match
exactly. A role called `andrei-lab-eks-cluster-role` is refused. The community
`terraform-aws-modules/eks` module names its own roles and therefore fails,
which is why this module uses the raw resources.

### 2. `eks:CreateNodegroup` is not granted at all

```
AccessDeniedException: User ... is not authorized to perform:
eks:CreateNodegroup ... because no identity-based policy allows the action
```

The policy grants `CreateCluster`, `CreateAddon`, `CreateFargateProfile`,
`DeleteCluster` — and **no node-group action**. The control plane builds fine;
only the compute is refused. Hence `create_node_group = false`.

Fargate is clearly the intended path, but the default VPC's subnets all have
`MapPublicIpOnLaunch = true` and **EKS Fargate requires private subnets**, so it
would need a private subnet plus a NAT gateway or VPC endpoints first.

**What you still get** is a real, ACTIVE control plane:

```
$ kubectl get nodes
No resources found

$ kubectl get pods -A
kube-system   coredns-7754cc59f4-fj4qf   0/1   Pending   0   4m3s
kube-system   coredns-7754cc59f4-hfqh9   0/1   Pending   0   4m3s
```

Which is itself instructive: CoreDNS is a Deployment the managed control plane
creates for you, and with no compute it simply sits `Pending`. It is a clean
picture of the split — AWS runs the control plane, **you** supply the nodes, and
nothing schedules until you do.

To see the node group actually work, run this module in your own account with
`create_node_group = true`.

### 3. The whole policy is time-boxed

Every statement carries `DateGreaterThan` / `DateLessThan` conditions spanning
three hours from session start. When the window closes, calls return
AccessDenied while the resources keep running — so a late failure may just be
the clock, not the config.

## Run it

```bash
../../scripts/tf-init.sh eks
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
#   public_access_cidrs = ["<your ip>/32"]
#   create_node_group   = false     # in the playground; see below
# get your IPv4 with:  curl -4 -s ifconfig.me     (-4 matters: an IPv6 address
# is rejected by a security-group rule)

terraform apply                 # ~9 min for the cluster, ~3 more for nodes

# Write the kubeconfig to its OWN FILE. Adding a lab context next to a
# production one in ~/.kube/config is how people run a delete against the wrong
# cluster -- and `kubectl config use-context` is sticky across shells.
export KUBECONFIG=~/.kube/andrei-lab-eks
aws eks update-kubeconfig --region us-east-1 --name andrei-lab-eks --alias andrei-lab-eks
kubectl --context andrei-lab-eks get nodes
kubectl --context andrei-lab-eks get pods -A

# with create_node_group = true (your own account):
kubectl --context andrei-lab-eks apply -f manifests/test-workload.yaml
kubectl --context andrei-lab-eks -n eks-test rollout status deploy/hello

# prove both nodes are serving
kubectl --context andrei-lab-eks -n eks-test port-forward svc/hello 8080:80 &
for i in $(seq 5); do curl -s localhost:8080 | jq -r '.environment.NODE_NAME'; done

terraform destroy
```

**Always pass `--context`.** A production kubeconfig sitting next to a lab one
in the same file is how people run `delete` against the wrong cluster.

## What to be able to say about it

**Managed vs self-installed.**

| k3s on EC2 | EKS |
|---|---|
| you run the control plane | AWS does; no ssh, no etcd access |
| one binary, one systemd unit | a managed API endpoint plus your node groups |
| kubeconfig written on the box | `aws eks update-kubeconfig` mints one |
| RBAC only | **IAM authenticates, then RBAC authorises** |
| node joins with a shared token | node joins via its IAM role |
| upgrade = re-run the installer | control plane and nodes upgrade **separately** |

**The two-step auth is the thing to understand.** An IAM principal with a
perfectly valid AWS session is still refused by the cluster unless it is mapped
in. This module sets `authentication_mode = "API_AND_CONFIG_MAP"`, so that
mapping is done with **access entries** — real API objects Terraform can manage.
The old way was hand-editing the `aws-auth` ConfigMap, where a YAML typo locked
every human out of the cluster with no validation and no way back in.

**Three node policies, all required.** `AmazonEKSWorkerNodePolicy` lets the
kubelet register, `AmazonEKS_CNI_Policy` lets the VPC CNI attach ENIs and give
pods **real VPC IP addresses** (not an overlay — this is why EKS pods are
directly routable and why you can exhaust a subnet with pods), and
`AmazonEC2ContainerRegistryReadOnly` lets nodes **pull** images. Push access to
a registry is not read access, and the node is a different principal from you.

**`ignore_changes` on `desired_size`.** Once anything autoscales the group, the
live size no longer matches the config, and Terraform would shrink it back on
the next apply. Managed node groups own that number after creation.

**Cost trap.** A `type: LoadBalancer` Service provisions a real billable ELB
that Terraform does not know about. Delete the Service before the cluster, or
it outlives `terraform destroy`. The test workload is `ClusterIP` for exactly
this reason.
