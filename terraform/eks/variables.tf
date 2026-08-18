variable "region" {
  type    = string
  default = "us-east-1"
}

variable "prefix" {
  type    = string
  default = "andrei-lab"
}

variable "cluster_version" {
  description = <<-EOT
    EKS control plane version.

    MINIMUM 1.33 -- that is Flux v2.9's documented floor
    (fluxcd.io/flux/installation/). Flux "may work" on older versions but the
    project neither recommends nor supports them, and building a GitOps demo on
    an unsupported control plane is not a production-grade story.

    Argo CD is far more relaxed about this; Flux is the binding constraint.
  EOT
  type        = string
  default     = "1.33"

  validation {
    condition     = tonumber(split(".", var.cluster_version)[1]) >= 33
    error_message = "Flux v2.9 requires Kubernetes >= 1.33."
  }
}

# ---------------------------------------------------------------------------
# THE PLAYGROUND CONSTRAINT THAT BREAKS EVERY OFF-THE-SHELF EKS MODULE.
#
# KodeKloud permits only two IAM roles, which already exist and must be used by
# exact name. The community terraform-aws-modules/eks module CREATES its roles,
# so it fails immediately with an AccessDenied on iam:CreateRole.
#
# Hence: raw aws_eks_cluster / aws_eks_node_group resources, and the roles come
# from data sources. In your own account, set create_iam_roles = true and this
# module builds them properly instead.
# ---------------------------------------------------------------------------
# VERIFIED AGAINST THE LIVE PLAYGROUND (account <ACCOUNT_ID>, 2026-08-18).
#
# The boundary policy AWS_EKSECSWithConditions permits iam:CreateRole ONLY for
# these exact role ARNs:
#
#   arn:aws:iam::<acct>:role/eksClusterRole
#   arn:aws:iam::<acct>:role/eksWorkerNodeRole
#   arn:aws:iam::<acct>:role/AmazonEKSFargatePodExecutionRole
#
# and iam:AttachRolePolicy only for AmazonEKSClusterPolicy,
# AmazonEKSWorkerNodePolicy, AmazonEKS_CNI_Policy,
# AmazonEC2ContainerRegistryReadOnly and AmazonSSMManagedInstanceCore.
#
# So the names are NOT cosmetic -- a role called "andrei-lab-eks-cluster-role"
# is refused, and so is attaching any policy outside that list. The names below
# are the permitted ones and are used by BOTH the create and the lookup path.
variable "create_iam_roles" {
  description = <<-EOT
    true  -> create the roles (they do not exist in a fresh playground, and the
             boundary policy permits creating exactly these names).
    false -> look them up, for a second run or an account where they pre-exist.
  EOT
  type        = bool
  default     = true
}

variable "cluster_role_name" {
  description = "Must be a name the boundary policy allows. Do not prefix it."
  type        = string
  default     = "eksClusterRole"
}

variable "node_role_name" {
  description = "eksWorkerNodeRole -- NOT AmazonEKSNodeRole, which the policy does not permit."
  type        = string
  default     = "eksWorkerNodeRole"
}

variable "node_instance_type" {
  description = "Playground ceiling is t3.medium."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  description = "Playground caps a node group at 3."
  type        = number
  default     = 3

  validation {
    condition     = var.node_max_size <= 3
    error_message = "The KodeKloud playground caps an EKS node group at 3 nodes."
  }
}

variable "node_disk_size" {
  type    = number
  default = 20
}

variable "public_access_cidrs" {
  description = "Who may reach the public Kubernetes API endpoint. Your /32 -- curl -s ifconfig.me"
  type        = list(string)

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Refusing to expose the Kubernetes API to the whole internet. Use your own /32."
  }
}

variable "excluded_azs" {
  description = <<-EOT
    Availability zones to keep out of the cluster regardless of what the
    instance-type offering API says. The subnet list is already filtered to AZs
    that offer node_instance_type; this is for a zone that offers the type but
    still cannot host an EKS control plane.

    EKS publishes no API for that, so it can only be discovered by trying --
    UnsupportedAvailabilityZoneException names the good zones in the message.
  EOT
  type        = list(string)
  default     = []
}

variable "create_node_group" {
  description = <<-EOT
    Provision the managed node group.

    false is REQUIRED in the KodeKloud playground: eks:CreateNodegroup is not in
    the boundary policy, so the cluster builds and the node group is refused with
    AccessDeniedException. You still get a real, ACTIVE control plane to inspect
    -- just no worker nodes, so no pods will schedule.

    true in an account with normal permissions.
  EOT
  type        = bool
  default     = true
}

variable "create_fargate" {
  description = <<-EOT
    Build private subnets, a NAT gateway and Fargate profiles.

    REQUIRED for any workload in this playground: eks:CreateNodegroup is denied,
    so Fargate is the only way to run a pod. Fargate in turn requires private
    subnets, which a default VPC does not have -- hence the NAT gateway.

    A NAT gateway is billed hourly plus per-GB. Destroy the stack when done.
  EOT
  type        = bool
  default     = false
}

variable "fargate_role_name" {
  description = "Fixed by the boundary policy -- it permits creating exactly this name."
  type        = string
  default     = "AmazonEKSFargatePodExecutionRole"
}

variable "fargate_namespaces" {
  description = <<-EOT
    Namespaces whose pods run on Fargate. A pod in a namespace with no matching
    profile stays Pending forever, and on a nodeless cluster that is every pod
    you forgot to list -- including CoreDNS, which is why kube-system is here.
  EOT
  type        = list(string)
  default     = ["kube-system", "argocd", "flux-system", "demo"]
}

variable "create_self_managed_nodes" {
  description = <<-EOT
    Real EC2 nodes via a launch template + autoscaling group, for clusters that
    cannot have a managed node group (eks:CreateNodegroup denied).

    Verified working: two nodes reached Healthy/InService and registered.
  EOT
  type        = bool
  default     = false
}
