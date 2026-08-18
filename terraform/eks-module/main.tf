# ---------------------------------------------------------------------------
# EKS via the community module -- terraform-aws-modules/eks
#
# WHY THE MODULE AND NOT HAND-ROLLED RESOURCES
# The module is ~170M downloads of tested edge cases: launch templates, the
# AL2023 nodeadm user-data format, access entries, security-group rules between
# control plane and nodes, and the ordering between all of them. Reimplementing
# that is how you discover each edge case personally.
#
# WHY THE HAND-ROLLED VERSION NEXT DOOR STILL EXISTS (terraform/eks)
# In a locked-down account, every resource the module creates by default is a
# potential AccessDenied, and the module's failure mode is opaque: you get a
# denial from somewhere inside 2,000 lines you did not write. The hand-rolled
# root module made every API call explicit while we mapped what this account
# actually permits. Keep both: the module for real work, the explicit one as the
# thing you read when the module is denied and you need to know why.
#
# WHAT HAD TO BE TURNED OFF FOR THIS ACCOUNT, AND WHY
#   create_iam_role = false     the boundary policy permits creating IAM roles
#                               with THREE exact names only. The module names
#                               its own roles after the cluster, so it cannot
#                               create them -- we pass in ours.
#   create_kms_key  = false     kms:CreateKey is not granted. The module would
#                               otherwise make a CMK for secret envelope
#                               encryption, which is the right default and
#                               simply unavailable here.
#   cloudwatch log group        logs:CreateLogGroup is not reliably granted.
#
# AND THE ONE THAT CANNOT BE TURNED OFF:
#   eks:CreateNodegroup is granted by NO policy on this account, so
#   eks_managed_node_groups is impossible. self_managed_node_groups is the way
#   through -- it is EC2 instances in an autoscaling group that join the cluster
#   themselves, which needs only ec2:RunInstances, autoscaling:*, iam:PassRole
#   and eks:CreateAccessEntry. A managed node group is AWS running that same
#   loop on your behalf; take away the API and you can still run the loop.
# ---------------------------------------------------------------------------

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

data "aws_vpc" "default" { default = true }

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  # Only AWS's own default subnets -- see the note in terraform/eks/main.tf
  # about a data source that can observe its own module's resources.
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

# us-east-1e offers neither t3.medium nor an EKS control plane. Filter on
# instance-type availability, which excludes it in practice.
data "aws_ec2_instance_type_offerings" "supported" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.node_instance_type]
  }
}

locals {
  subnets_by_az = {
    for id, s in data.aws_subnet.default : s.availability_zone => id
    if contains(data.aws_ec2_instance_type_offerings.supported.locations, s.availability_zone)
  }
  subnet_ids = [for az in sort(keys(local.subnets_by_az)) : local.subnets_by_az[az]]
}

# --- the two roles whose names this account permits -------------------------
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
  name               = "eksClusterRole"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
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
  name               = "eksWorkerNodeRole"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# A self-managed node is an EC2 instance, and an EC2 instance assumes a role
# through an INSTANCE PROFILE, not directly. Managed node groups hide this.
resource "aws_iam_instance_profile" "node" {
  name = "eksWorkerNodeRole"
  role = aws_iam_role.node.name
}

# --- the cluster ------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "${var.prefix}-eks"
  kubernetes_version = var.kubernetes_version

  vpc_id     = data.aws_vpc.default.id
  subnet_ids = local.subnet_ids

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.public_access_cidrs

  # Bring our own -- see the header.
  create_iam_role = false
  iam_role_arn    = aws_iam_role.cluster.arn

  # Unavailable on this account.
  #
  # encryption_config must be NULL, not {}. The module gates the block on
  # `var.encryption_config != null`, so an empty object still emits it -- with
  # no key, which fails at plan time:
  #
  #   The argument "encryption_config.0.provider.0.key_arn" is required
  #
  # Envelope encryption of secrets with a customer-managed key is the right
  # default and the module is right to want it; kms:CreateKey simply is not
  # granted here.
  create_kms_key              = false
  encryption_config           = null
  create_cloudwatch_log_group = false
  enabled_log_types           = []

  # The caller becomes cluster admin without hand-editing aws-auth.
  enable_cluster_creator_admin_permissions = true

  self_managed_node_groups = {
    default = {
      instance_type = var.node_instance_type
      min_size      = var.node_min_size
      max_size      = var.node_max_size
      desired_size  = var.node_desired_size

      # BOTH are needed, and the second is easy to miss.
      #   iam_instance_profile_arn -- what the EC2 instances assume
      #   iam_role_arn             -- what the module registers as the cluster
      #                               ACCESS ENTRY principal, so the kubelet is
      #                               recognised as a node
      # Omitting iam_role_arn fails with "principal_arn is required", pointing
      # at aws_eks_access_entry rather than at the input you forgot.
      create_iam_instance_profile = false
      iam_instance_profile_arn    = aws_iam_instance_profile.node.arn
      iam_role_arn                = aws_iam_role.node.arn
    }
  }

  tags = { Project = var.prefix }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy_attachment.node,
  ]
}
