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
  description = <<-EOT
    The cap here is the account's EC2 instance allowance, not an EKS limit --
    self-managed nodes are plain EC2 instances in an ASG. A *managed* node group
    is capped at 3 on this playground, which is a different ceiling and does not
    apply.

    5 is the observed instance allowance, and with no Elasticsearch lab running
    all 5 are available to the cluster.
  EOT
  type        = number
  default     = 4

  validation {
    condition     = var.node_max_size <= 5
    error_message = "The playground allows 5 EC2 instances in total."
  }
}

variable "node_max_pods" {
  description = <<-EOT
    kubelet's --max-pods, pinned rather than computed.

    EKS caps pods per node by ENI, not CPU: every pod takes a real VPC IP, so a
    t3.medium allows 17 pods however idle it is. nodeadm computes that ceiling
    at bootstrap from the instance type and writes it into the kubelet config.

    ENABLE_PREFIX_DELEGATION on the aws-node daemonset makes the CNI hand out
    /28 prefixes instead of single IPs, which raises the real ceiling to 110 --
    but nodeadm does not know that, so kubelet keeps advertising 17 and the node
    stays full. BOTH halves are required: the CNI env var AND this number.

    Order matters. kubelet reads this once at bootstrap, so the daemonset must
    already carry ENABLE_PREFIX_DELEGATION before a node joins. scripts/eks-up.sh
    does that in three phases.

    Set to 0 to leave nodeadm's calculation alone.
  EOT
  type        = number
  default     = 110

  validation {
    condition     = var.node_max_pods == 0 || (var.node_max_pods >= 17 && var.node_max_pods <= 110)
    error_message = "max-pods must be 0 (let nodeadm decide) or between 17 and 110."
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

variable "node_service_ports" {
  description = <<-EOT
    NodePorts to open on the cluster security group, as name => port.

    Named rather than a bare list so that `terraform state list` and the AWS
    console both say WHAT each hole is for. A security group full of anonymous
    30xxx rules is one nobody dares close.
  EOT
  type        = map(number)
  default = {
    argocd-ui-http    = 30083
    argocd-ui-https   = 30084 # also the GitHub webhook endpoint
    podinfo-argocd    = 30081
    podinfo-flux      = 30082
    podinfo-rollouts  = 30085
    flux-ui           = 30086 # UNAUTHENTICATED -- see node_service_cidrs
    ingress-nginx     = 30090
    ingress-nginx-tls = 30443
    grafana           = 30091
    prometheus        = 30092 # UNAUTHENTICATED -- see node_service_cidrs
    apisix-gateway    = 30093

    # DELIBERATELY ABSENT: the APISIX Admin API.
    #
    # It is authenticated by a single static shared key and it can rewrite every
    # route in the gateway -- so it is the one component here where "public
    # because the lab is ephemeral" is not a good enough reason. It stays
    # ClusterIP; reach it with a port-forward when you need it.
    #
    # Also absent: etcd. Nothing outside the cluster has any business reaching
    # the gateway's config store directly.
  }
}

variable "node_service_cidrs" {
  description = <<-EOT
    Who may reach those NodePorts.

    Defaults to the whole internet, which is a deliberate choice for a
    time-boxed playground with password-protected services -- and the wrong
    default for anything that outlives an afternoon.

    ONE OF THEM IS NOT PASSWORD-PROTECTED, and the asymmetry is worth knowing
    before copying this anywhere. Argo CD's UI asks for a password. The Flux
    Operator UI on 30086 does not: it answers 200 with no WWW-Authenticate
    header at all. Opening it publishes a read-only view of everything the
    cluster is running to anyone who has the node IP.

    Fine for a lab that exists for three hours. For anything else, either drop
    flux-ui from node_service_ports and reach it over a port-forward:

      kubectl -n flux-system port-forward svc/flux-operator 9080:9080

    or put it behind an ingress that authenticates.

    Narrow everything to your own /32 with:

      node_service_cidrs = ["$(curl -4 -s https://checkip.amazonaws.com)/32"]

    Note `-4`: curl returns IPv6 on some networks and a security group rule
    wants IPv4.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
