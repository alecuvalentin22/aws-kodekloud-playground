# ---------------------------------------------------------------------------
# PRIVATE SUBNETS + NAT + FARGATE
#
# Why this file exists: the playground grants eks:CreateCluster and
# eks:CreateFargateProfile but NOT eks:CreateNodegroup (verified on three
# separate accounts). So there is no way to attach EC2 compute to this cluster
# -- Fargate is the only option.
#
# And Fargate has a hard requirement the default VPC cannot meet:
#
#   "Fargate profiles support private subnets only."
#
# A subnet is "private" to EKS if its route table has NO route to an internet
# gateway. Every subnet in a default VPC routes 0.0.0.0/0 at the IGW, so all of
# them are public and a Fargate profile referencing them is rejected outright.
#
# Hence: build real private subnets, give them a NAT gateway for egress (Fargate
# pods must reach ECR to pull images and the EKS API to register), and point the
# Fargate profiles at those.
# ---------------------------------------------------------------------------

locals {
  # Two AZs is the EKS minimum. Reuse the AZ list already filtered for
  # instance-type availability -- us-east-1e is excluded there, and it is
  # exactly the zone that also refuses EKS control planes.
  fargate_azs = slice(sort(keys(local.subnets_by_az)), 0, 2)
}

resource "aws_subnet" "private" {
  for_each = var.create_fargate ? toset(local.fargate_azs) : toset([])

  vpc_id            = data.aws_vpc.default.id
  availability_zone = each.value
  # 172.31.200.0/24 and .201.0/24 -- inside the default VPC's /16 but clear of
  # the 172.31.0-96 ranges AWS hands out to its own default subnets.
  cidr_block = cidrsubnet("172.31.200.0/22", 2, index(local.fargate_azs, each.value))

  # The defining property: no public IPs, and (below) no IGW route.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.prefix}-private-${each.value}"
    # Required for EKS to place its ENIs here.
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# One NAT gateway, not one per AZ. Production would use one per AZ so a zone
# failure cannot take out egress for the others; this is a lab and each NAT is
# billed hourly plus per-GB.
resource "aws_eip" "nat" {
  count  = var.create_fargate ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.prefix}-nat" }
}

resource "aws_nat_gateway" "this" {
  count = var.create_fargate ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  # The NAT itself must sit in a PUBLIC subnet -- it is the thing with the
  # route to the internet gateway. Only the workloads behind it are private.
  subnet_id = local.subnet_ids[0]

  tags = { Name = "${var.prefix}-nat" }
}

resource "aws_route_table" "private" {
  count  = var.create_fargate ? 1 : 0
  vpc_id = data.aws_vpc.default.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[0].id
  }

  tags = { Name = "${var.prefix}-private" }
}

resource "aws_route_table_association" "private" {
  for_each = var.create_fargate ? aws_subnet.private : {}

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[0].id
}

# --- Fargate pod execution role ---------------------------------------------
# Distinct from the CLUSTER role and from a node role. Fargate has no node, so
# this is the identity the pod's infrastructure assumes to pull images and write
# logs. The name is fixed by the boundary policy.
data "aws_iam_policy_document" "fargate_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks-fargate-pods.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fargate" {
  count              = var.create_fargate ? 1 : 0
  name               = var.fargate_role_name
  assume_role_policy = data.aws_iam_policy_document.fargate_assume.json
}

resource "aws_iam_role_policy_attachment" "fargate" {
  count      = var.create_fargate ? 1 : 0
  role       = aws_iam_role.fargate[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}

# --- Fargate profiles --------------------------------------------------------
# A profile is a SELECTOR, not a pool: any pod whose namespace (and optionally
# labels) matches gets scheduled onto Fargate. A pod matching no profile stays
# Pending forever, which on a cluster with no nodes is every pod you forget.
#
# kube-system is listed first and deliberately: on a node-group cluster CoreDNS
# runs on nodes, so a Fargate-only cluster leaves it Pending and DNS never works.
# It also carries an annotation marking it as EC2-scheduled, which has to be
# removed -- see the null_resource below.
resource "aws_eks_fargate_profile" "this" {
  for_each = var.create_fargate ? toset(var.fargate_namespaces) : toset([])

  cluster_name           = aws_eks_cluster.this.name
  fargate_profile_name   = "${var.prefix}-${each.value}"
  pod_execution_role_arn = aws_iam_role.fargate[0].arn
  subnet_ids             = [for s in aws_subnet.private : s.id]

  selector {
    namespace = each.value
  }

  depends_on = [aws_iam_role_policy_attachment.fargate]
}
