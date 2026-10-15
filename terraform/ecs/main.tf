# Artifactory OSS on ECS Fargate -- deliberately NOT on the EKS cluster.
#
# Why Fargate for this one piece:
#
#   - the playground allows 5 EC2 instances in total, and Fargate tasks do not
#     count against that. Every GiB moved here is a GiB the EKS nodes keep for
#     Jenkins builds.
#   - it starts in parallel with the EKS build instead of queuing behind it.
#   - Artifactory's Helm chart pulls in a Bitnami PostgreSQL subchart, and
#     Bitnami's public images are gone (subscription-only since 2025). As one
#     container with the embedded database it has no subchart to break.
#
# The trade, stated plainly: ephemeral storage and the embedded Derby database.
# Restart the task and the artifacts are gone. For a training lab that is
# acceptable; for anything real it is EFS (or EBS) plus an external PostgreSQL,
# and at that point Kubernetes with a PVC is the more natural home.
#
# NO IAM ROLE. A task execution role is only needed to pull from PRIVATE ECR,
# ship logs to CloudWatch, or read Secrets Manager. A public image needs none --
# which matters here, because this playground only allows creating three role
# names.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_security_group" "artifactory" {
  name_prefix = "${var.prefix}-artifactory-"
  description = "Artifactory UI/API"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Artifactory UI and REST API"
    from_port   = 8082
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = var.ui_cidrs
  }

  # Image pull from releases-docker.jfrog.io and nothing else needed, but
  # Fargate has no egress filtering short of a NAT/firewall, so be honest that
  # this is open.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_ecs_cluster" "this" {
  name = var.prefix
}

resource "aws_ecs_task_definition" "artifactory" {
  family                   = "artifactory-oss"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  # 1 vCPU / 4 GiB. Artifactory is a JVM and will not start in less than ~2 GiB.
  cpu    = "1024"
  memory = "4096"

  ephemeral_storage {
    size_in_gib = 30
  }

  container_definitions = jsonencode([{
    name      = "artifactory"
    image     = "releases-docker.jfrog.io/jfrog/artifactory-oss:${var.artifactory_version}"
    essential = true
    portMappings = [{
      containerPort = 8082
      protocol      = "tcp"
    }]
    environment = [
      # Embedded database: one container, no PostgreSQL to run.
      { name = "JF_SHARED_DATABASE_TYPE", value = "derby" },
    ]
    ulimits = [{
      name      = "nofile"
      softLimit = 32000
      hardLimit = 40000
    }]
  }])
}

# A SERVICE, not a one-off task: ECS restarts it if the container dies, which is
# the property you actually want from "run this container somewhere".
resource "aws_ecs_service" "artifactory" {
  name            = "artifactory"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.artifactory.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.artifactory.id]
    assign_public_ip = true
  }

  # Artifactory takes 2-4 minutes to come up. Without a grace period on a
  # health-checked service ECS would kill it mid-start, forever.
  wait_for_steady_state = false
}
