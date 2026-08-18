# Uses the DEFAULT VPC on purpose. The KodeKloud playground restricts VPC
# creation, and a default VPC already exists there. In your own account this
# still works fine -- swap in a dedicated VPC later if you want the practice.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---------------------------------------------------------------------------
# NOT EVERY INSTANCE TYPE EXISTS IN EVERY AVAILABILITY ZONE.
#
# Found the hard way on 2026-08-18: spreading three nodes round-robin across
# the default VPC's six subnets put one in us-east-1e, and
#
#   Unsupported: Your requested instance type (t3.medium) is not supported in
#   your requested Availability Zone (us-east-1e).
#
# us-east-1e is an old zone with old hardware and no Nitro-generation types.
# The failure arrives at RunInstances -- after the plan has been accepted, and
# after everything else in the graph has already been built.
#
# An AZ list can never be hardcoded: it differs per account, per region and per
# instance type. So ask the API which zones actually offer the type, and place
# instances only there.
# ---------------------------------------------------------------------------
data "aws_ec2_instance_type_offerings" "supported" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

locals {
  # Subnets whose AZ actually offers var.instance_type, keyed by AZ.
  usable_subnets_by_az = {
    for id, subnet in data.aws_subnet.default : subnet.availability_zone => id
    if contains(data.aws_ec2_instance_type_offerings.supported.locations, subnet.availability_zone)
  }

  # Ordered by AZ NAME, not by subnet ID. Two reasons: the mapping is stable, so
  # an unrelated change cannot silently propose moving an instance to another
  # subnet (which is a replacement, not an update); and the placement is
  # predictable -- es-01 in us-east-1a, es-02 in 1b, es-03 in 1c -- which makes
  # "is my cluster actually spread across zones?" answerable at a glance.
  usable_subnet_ids = [for az in sort(keys(local.usable_subnets_by_az)) : local.usable_subnets_by_az[az]]
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "lab" {
  key_name   = "${var.prefix}-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_security_group" "lab" {
  name        = "${var.prefix}-sg"
  description = "Platform lab"
  vpc_id      = data.aws_vpc.default.id

  # SSH from you only.
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Kibana, MinIO console, Rancher, Kong -- from you only.
  ingress {
    description = "Kibana"
    from_port   = 5601
    to_port     = 5601
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress {
    description = "MinIO API + console"
    from_port   = 9000
    to_port     = 9001
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress {
    description = "Elasticsearch HTTP (for your curl drills)"
    from_port   = 9200
    to_port     = 9200
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress {
    description = "k3s API + Kong NodePort + Rancher"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress {
    description = "HTTPS for Rancher ingress"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Cluster-internal traffic: nodes talk to each other freely.
  ingress {
    description = "intra-cluster"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-sg" }
}

locals {
  # KodeKloud forbids t3 "unlimited" credit mode -- it suspends your session.
  needs_standard_credits = startswith(var.instance_type, "t2.") || startswith(var.instance_type, "t3.")
}

resource "aws_instance" "es" {
  count = var.es_node_count

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = local.usable_subnet_ids[count.index % length(local.usable_subnet_ids)]
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.lab.id]

  dynamic "credit_specification" {
    for_each = local.needs_standard_credits ? [1] : []
    content {
      cpu_credits = "standard"
    }
  }

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = var.volume_type
    delete_on_termination = true
  }

  tags = {
    Name = "${var.prefix}-es-0${count.index + 1}"
    Role = "elasticsearch"
  }
}

resource "aws_instance" "k8s" {
  count = var.create_k8s_node ? 1 : 0

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = local.usable_subnet_ids[0]
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.lab.id]

  dynamic "credit_specification" {
    for_each = local.needs_standard_credits ? [1] : []
    content {
      cpu_credits = "standard"
    }
  }

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = var.volume_type
    delete_on_termination = true
  }

  tags = {
    Name = "${var.prefix}-k3s-01"
    Role = "k8s"
  }
}

# ---------------------------------------------------------------------------
# Dedicated EBS data volumes for Elasticsearch.
#
# WHY NOT JUST USE THE ROOT VOLUME:
#   1. Data outlives the instance. delete_on_termination = false means you can
#      terminate a node, launch a replacement and reattach the same disk --
#      which is how you would actually replace a failed ES node in production.
#   2. Filling the data disk does not take the OS down with it. The disk
#      watermark drill (drills/03) deliberately fills this volume until
#      Elasticsearch flips indices to read-only; on a shared root volume that
#      same test also breaks sshd, apt and journald.
#   3. A small data volume makes that drill fast -- 10 GiB fills in seconds,
#      a 30 GiB root volume does not.
#
# The volume MUST be in the same AZ as the instance: EBS is an
# availability-zone-scoped resource and cannot cross one. That is the single
# most common EBS mistake, and it is why availability_zone here is read back
# off the instance rather than set independently.
# ---------------------------------------------------------------------------
resource "aws_ebs_volume" "es_data" {
  count = var.data_volume_gb > 0 ? var.es_node_count : 0

  availability_zone = aws_instance.es[count.index].availability_zone
  size              = var.data_volume_gb
  type              = var.volume_type

  # gp3 lets you buy IOPS independently of capacity; gp2 derives them from size
  # (3 IOPS/GiB), so a small gp2 volume is also a slow one. Only send these when
  # the type actually supports them.
  iops       = var.volume_type == "gp3" ? var.data_volume_iops : null
  throughput = var.volume_type == "gp3" ? var.data_volume_throughput : null

  encrypted = true

  tags = {
    Name = "${var.prefix}-es-0${count.index + 1}-data"
    Role = "elasticsearch-data"
  }
}

resource "aws_volume_attachment" "es_data" {
  count = var.data_volume_gb > 0 ? var.es_node_count : 0

  # NITRO GOTCHA: t3/m5/c5 and everything newer expose EBS over NVMe, and the
  # kernel ignores this name entirely -- the disk turns up as /dev/nvme1n1, and
  # the number is assigned in attach order, so it is not even stable across
  # reboots. device_name here is only what the AWS API records.
  #
  # This is why the Ansible storage role resolves the disk through
  # /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<volume-id>, which is
  # deterministic. The volume ID is handed to Ansible through the generated
  # inventory -- see outputs.tf.
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.es_data[count.index].id
  instance_id = aws_instance.es[count.index].id

  # Detach cleanly on destroy rather than yanking the disk out from under a
  # mounted filesystem.
  stop_instance_before_detaching = true
}

# ---------------------------------------------------------------------------
# A second Kubernetes node, running RKE2 instead of k3s.
#
# THE POINT: Rancher is a management plane, and the claim worth being able to
# make is that it does not care what is underneath. Proving that needs TWO
# distributions, not one -- see drills/07.
#
# It is also the pragmatic fix for a 4 GiB node: Rancher (~1.5 GiB) and Keycloak
# (~1 GiB) do not fit on one t3.medium alongside k3s and Kong. Giving Rancher
# its own box means both can run at once, which is what the lab actually wants.
#
# 3 ES + k3s + this = 5, exactly the playground's instance cap. Nothing else
# fits, which is why data_volume_gb and create_rds exist as off switches.
# ---------------------------------------------------------------------------
resource "aws_instance" "rancher" {
  count = var.create_rancher_node ? 1 : 0

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = local.usable_subnet_ids[0]
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.lab.id]

  dynamic "credit_specification" {
    for_each = local.needs_standard_credits ? [1] : []
    content {
      cpu_credits = "standard"
    }
  }

  root_block_device {
    # RKE2 is heavier on disk than k3s -- containerd images, the static-pod
    # control plane and its bundled CNI.
    volume_size           = var.root_volume_gb
    volume_type           = var.volume_type
    delete_on_termination = true
  }

  tags = {
    Name = "${var.prefix}-rke2-01"
    Role = "rancher"
  }
}
