# ---------------------------------------------------------------------------
# A small EKS cluster and managed node group.
#
# The point of this module is NOT to host the lab -- it cannot. The playground
# caps EKS at 3 pods per namespace and 512 MiB / 256m per pod, which Rancher
# alone exceeds. The point is to see how a MANAGED control plane differs from
# the k3s/RKE2 install next door:
#
#   k3s on EC2                        EKS
#   --------------------------------- ------------------------------------------
#   you run the control plane         AWS does; you cannot ssh to it or see etcd
#   one binary, one systemd unit      a managed API endpoint + your node groups
#   kubeconfig written on the box     `aws eks update-kubeconfig` mints one
#   RBAC only                         IAM authenticates, THEN RBAC authorises
#   node joins with a shared token    node joins via its IAM role + access entry
#   upgrade = re-run the installer    control plane and nodes upgrade separately
#
# The IAM-then-RBAC split is the one worth being able to explain: an IAM
# principal that is not mapped into the cluster gets a perfectly valid AWS
# session and is still refused by Kubernetes.
# ---------------------------------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# EKS needs subnets in at least two availability zones for the control plane's
# cross-AZ ENIs. The default VPC has one per AZ, so this is satisfied -- but it
# is a real failure mode when someone hands EKS a single-AZ subnet list.
data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

data "aws_caller_identity" "current" {}

# Which AZs offer the node instance type. Doubles as the EKS control-plane
# filter -- see the comment on usable_subnet_ids below.
data "aws_ec2_instance_type_offerings" "supported" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.node_instance_type]
  }
}

locals {
  cluster_name = "${var.prefix}-eks"

  # Exactly one subnet per availability zone, deterministically ordered so the
  # plan is stable across runs. A default VPC already has one per AZ, but a
  # real VPC usually has several (public/private/db tiers) and handing EKS all
  # of them scatters the control-plane ENIs and the nodes across tiers that
  # were meant to stay separate.
  #
  # The `{for ...}` builds az -> id, and a map keeps only the LAST value per
  # key, which is the dedup. sort() on the keys makes it deterministic.
  #
  # ---------------------------------------------------------------------
  # AND THEN THE AZ FILTER. Found live on 2026-08-18:
  #
  #   UnsupportedAvailabilityZoneException: Cannot create cluster because EKS
  #   does not support creating control plane instances in us-east-1e
  #
  # us-east-1e is an old zone that several services simply do not offer. There
  # is no "does EKS support this AZ" API to query, so this filters on the NODE
  # INSTANCE TYPE's availability instead -- which is a real constraint in its
  # own right (the node group cannot launch t3.medium there either) and which
  # excludes the same zones in practice.
  #
  # excluded_azs is the escape hatch for the case where those two sets ever
  # diverge: a zone that offers the instance type but not the EKS control plane.
  # ---------------------------------------------------------------------
  subnets_by_az = {
    for id, s in data.aws_subnet.default : s.availability_zone => id
    if contains(data.aws_ec2_instance_type_offerings.supported.locations, s.availability_zone)
    && !contains(var.excluded_azs, s.availability_zone)
  }
  subnet_ids = [for az in sort(keys(local.subnets_by_az)) : local.subnets_by_az[az]]

  cluster_role_arn = var.create_iam_roles ? aws_iam_role.cluster[0].arn : data.aws_iam_role.cluster[0].arn
  node_role_arn    = var.create_iam_roles ? aws_iam_role.node[0].arn : data.aws_iam_role.node[0].arn
}

# --- IAM ---------------------------------------------------------------------
# Playground path: the roles already exist and are the only ones permitted.
data "aws_iam_role" "cluster" {
  count = var.create_iam_roles ? 0 : 1
  name  = var.cluster_role_name
}

data "aws_iam_role" "node" {
  count = var.create_iam_roles ? 0 : 1
  name  = var.node_role_name
}

# Own-account path: build them, which is also the readable documentation of
# what those two roles actually have to contain.
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  count              = var.create_iam_roles ? 1 : 0
  name               = var.cluster_role_name
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  count      = var.create_iam_roles ? 1 : 0
  role       = aws_iam_role.cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  count              = var.create_iam_roles ? 1 : 0
  name               = var.node_role_name
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

# Three separate managed policies, and all three are required:
#   WorkerNodePolicy  - lets the kubelet register with the control plane
#   CNI_Policy        - lets the VPC CNI attach ENIs and hand pods REAL VPC IPs
#   ECR ReadOnly      - lets the node PULL images (a separate grant from push)
resource "aws_iam_role_policy_attachment" "node" {
  for_each = var.create_iam_roles ? toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]) : toset([])

  role       = aws_iam_role.node[0].name
  policy_arn = each.value
}

# --- Cluster -----------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  role_arn = local.cluster_role_arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids = local.subnet_ids

    # Public endpoint so you can reach it from your laptop; private so nodes
    # talk to it inside the VPC rather than hairpinning out. Locking
    # public_access_cidrs to your own /32 is what makes the public endpoint
    # acceptable -- the variable validation refuses 0.0.0.0/0.
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = var.public_access_cidrs
  }

  # API_AND_CONFIG_MAP is the modern replacement for editing the aws-auth
  # ConfigMap by hand. Access entries are real API objects Terraform can manage;
  # aws-auth was a ConfigMap where a YAML typo silently locked everyone out of
  # the cluster, with no validation and no way back in.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Control-plane logs go to CloudWatch. Without this, "why was my pod denied?"
  # has no audit trail at all -- and you cannot read the API server's log any
  # other way, because you do not own the machine it runs on.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  tags = { Name = local.cluster_name }
}

# --- Node group --------------------------------------------------------------
# VERIFIED DENIED IN THE KODEKLOUD PLAYGROUND (2026-08-18):
#
#   AccessDeniedException: User ... is not authorized to perform:
#   eks:CreateNodegroup ... because no identity-based policy allows the
#   eks:CreateNodegroup action
#
# The boundary policy grants eks:CreateCluster, CreateAddon, CreateFargateProfile
# and DeleteCluster -- and no node-group action at all. The CLUSTER builds fine;
# only the compute does not.
#
# Fargate is the intended path there, but the default VPC's subnets all have
# MapPublicIpOnLaunch = true and EKS Fargate requires PRIVATE subnets, so it
# needs a private subnet plus a NAT gateway or VPC endpoints before it will work.
#
# So: set create_node_group = false to get a working control plane in the
# playground, and leave it true in a real account.
resource "aws_eks_node_group" "this" {
  count = var.create_node_group ? 1 : 0

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.prefix}-ng"
  node_role_arn   = local.node_role_arn
  subnet_ids      = local.subnet_ids

  instance_types = [var.node_instance_type]
  disk_size      = var.node_disk_size
  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # Rolling replacement: at most one node unavailable during an upgrade. The
  # managed node group cordons, drains and replaces nodes for you -- the
  # equivalent of the `serial: 1` rolling restart the Ansible elastic play does
  # by hand, except AWS runs it.
  update_config {
    max_unavailable = 1
  }

  # desired_size drifts once anything autoscales. Terraform would fight it on
  # every apply and shrink the cluster back.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  # Without this the node group can be created before the role's policies are
  # attached, and the kubelet fails to register -- an implicit dependency
  # Terraform cannot infer, because the node group references the role, not the
  # attachments.
  depends_on = [aws_iam_role_policy_attachment.node]

  tags = { Name = "${var.prefix}-ng" }
}
