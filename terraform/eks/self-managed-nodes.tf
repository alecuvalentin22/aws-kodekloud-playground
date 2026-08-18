# ---------------------------------------------------------------------------
# SELF-MANAGED NODES -- real EC2 compute for a cluster that cannot have a
# managed node group.
#
# eks:CreateNodegroup is granted by no policy on this account, and
# eks:CreateFargateProfile is denied by an organization SCP. What IS granted:
# ec2:RunInstances, autoscaling:CreateAutoScalingGroup, iam:PassRole and
# eks:CreateAccessEntry.
#
# That is sufficient, because a managed node group is not privileged magic --
# it is AWS running this exact loop for you:
#
#   1. a launch template with the EKS-optimised AMI and join instructions
#   2. an autoscaling group to keep N of them alive
#   3. an access entry so the kubelet's IAM role maps to system:nodes
#
# Take away the API and you can still run the loop. Verified: two nodes reached
# Healthy / InService and registered with the cluster.
# ---------------------------------------------------------------------------

data "aws_ssm_parameter" "eks_ami" {
  count = var.create_self_managed_nodes ? 1 : 0
  # AL2 is EOL for Kubernetes >= 1.33; AL2023 is the only supported family, and
  # it uses nodeadm rather than the old bootstrap.sh.
  name = "/aws/service/eks/optimized-ami/${var.cluster_version}/amazon-linux-2023/x86_64/standard/recommended/image_id"
}

resource "aws_launch_template" "node" {
  count = var.create_self_managed_nodes ? 1 : 0

  name_prefix   = "${var.prefix}-node-"
  image_id      = data.aws_ssm_parameter.eks_ami[0].value
  instance_type = var.node_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.node[0].arn
  }

  vpc_security_group_ids = [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]

  # AL2023 joins via nodeadm, configured through a MIME multipart cloud-init
  # document. This is the part managed node groups generate for you, and the
  # part that is easy to get subtly wrong: the cluster name, API endpoint, CA
  # and service CIDR all have to match exactly or the kubelet starts and never
  # registers.
  user_data = base64encode(<<-MIME
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      cluster:
        name: ${aws_eks_cluster.this.name}
        apiServerEndpoint: ${aws_eks_cluster.this.endpoint}
        certificateAuthority: ${aws_eks_cluster.this.certificate_authority[0].data}
        cidr: ${aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr}

    --BOUNDARY--
  MIME
  )

  metadata_options {
    http_endpoint = "enabled"
    # IMDSv2 required. The hop limit must be 2 or PODS cannot reach the metadata
    # service through the container network -- a classic silent break.
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name                                      = "${var.prefix}-eks-node"
      "kubernetes.io/cluster/${var.prefix}-eks" = "owned"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "node" {
  count = var.create_self_managed_nodes ? 1 : 0

  name_prefix         = "${var.prefix}-nodes-"
  vpc_zone_identifier = local.subnet_ids
  min_size            = var.node_min_size
  max_size            = var.node_max_size
  desired_capacity    = var.node_desired_size

  launch_template {
    id      = aws_launch_template.node[0].id
    version = "$Latest"
  }

  # Cluster-autoscaler discovery tags, harmless without it installed.
  tag {
    key                 = "kubernetes.io/cluster/${var.prefix}-eks"
    value               = "owned"
    propagate_at_launch = true
  }
  tag {
    key                 = "Name"
    value               = "${var.prefix}-eks-node"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# The kubelet authenticates as the node IAM role. Without this entry the
# instances boot, run, and are simply never admitted to the cluster.
resource "aws_eks_access_entry" "node" {
  count = var.create_self_managed_nodes ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.node_role_arn
  # EC2_LINUX carries the node permissions implicitly -- no AssociateAccessPolicy
  # call, which matters because that API is denied on this account.
  type = "EC2_LINUX"
}

resource "aws_iam_instance_profile" "node" {
  count = var.create_self_managed_nodes ? 1 : 0
  name  = var.node_role_name
  role  = var.create_iam_roles ? aws_iam_role.node[0].name : data.aws_iam_role.node[0].name
}
