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

locals {
  # The nodeadm document, built as a data structure and serialised. spec.kubelet
  # is merged in rather than templated in, so "omit it" is an empty map and not
  # a conditional in the middle of whitespace-significant text.
  nodeadm_config = yamlencode({
    apiVersion = "node.eks.aws/v1alpha1"
    kind       = "NodeConfig"
    spec = merge(
      {
        cluster = {
          name                 = aws_eks_cluster.this.name
          apiServerEndpoint    = aws_eks_cluster.this.endpoint
          certificateAuthority = aws_eks_cluster.this.certificate_authority[0].data
          cidr                 = aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr
        }
      },
      var.node_max_pods > 0 ? {
        # spec.kubelet.config is passed through verbatim into kubelet's
        # KubeletConfiguration file, so anything valid there is valid here.
        kubelet = {
          config = {
            maxPods = var.node_max_pods
          }
        }
      } : {}
    )
  })

  # MIME assembled by join rather than a heredoc, for the same reason: no
  # implicit indentation stripping anywhere near the payload.
  node_user_data = join("\n", [
    "MIME-Version: 1.0",
    "Content-Type: multipart/mixed; boundary=\"BOUNDARY\"",
    "",
    "--BOUNDARY",
    "Content-Type: application/node.eks.aws",
    "",
    local.nodeadm_config,
    "--BOUNDARY--",
    "",
  ])
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
  #
  # maxPods is pinned here rather than left to nodeadm. nodeadm derives it from
  # the instance type's ENI capacity -- 17 on a t3.medium -- and writes it into
  # the kubelet config at bootstrap. Prefix delegation raises the CNI's real
  # ceiling to 110 but cannot retroactively change a number kubelet has already
  # read, so the node would sit at 17 forever. See var.node_max_pods.
  #
  # NOT a heredoc template. This was written as `<<-MIME` with a `%{if}` around
  # the kubelet block, and it produced YAML that was silently wrong:
  #
  #     cidr: 10.100.0.0/16
  #       kubelet:          <- 6 spaces
  #     config:             <- 4 spaces
  #
  # `<<-` strips the smallest common indent across all lines, and the `%{if}`
  # marker line participates in that calculation while contributing no output.
  # Move the directive and every line after it shifts. The instances booted,
  # nodeadm rejected the config, and three EC2 nodes ran for 20 minutes without
  # ever registering -- with no error anywhere in the AWS console, because from
  # EC2's point of view the launch succeeded.
  #
  # yamlencode cannot produce misindented YAML. Reach for it whenever generated
  # YAML is indentation-sensitive, which is always.
  user_data = base64encode(local.node_user_data)

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
