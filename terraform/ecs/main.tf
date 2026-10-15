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

# Master and join keys, supplied rather than generated on first boot.
#
# Left to itself, Artifactory's access service generates the master key while
# the core service waits for it -- for 60 seconds. On a single throttled vCPU
# access was still starting when the wait expired, and the core gave up:
#   Master key is missing. Pending for 5 seconds with 60 seconds timeout
#   Failed initializing Home. Caught exception:
# with the container still RUNNING. The Helm chart always supplies these keys,
# which is why nobody using the chart sees this.
#
# Plain env vars, so they sit in the task definition and in Terraform state.
# Acceptable for a three-hour lab with nothing in it; in production they come
# from Secrets Manager via `secrets`, which needs a task execution role this
# playground does not allow.
resource "random_id" "master_key" {
  byte_length = 32
}

resource "random_id" "join_key" {
  byte_length = 32
}

resource "aws_ecs_task_definition" "artifactory" {
  family                   = "artifactory-oss"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  # 2 vCPU / 8 GiB. Memory was never the problem; CPU was.
  #
  # Artifactory is EIGHT services in one container (router, access, core,
  # metadata, frontend, event, observability, topology), and they start in
  # parallel against hard timeouts. On 1 vCPU, access took 364 s to start:
  #   Started AccessApplication in 364.758 seconds
  # and the router -- the process that serves :8082 -- had already given up:
  #   [jfrou] [FATAL] Failed joining Access: ... context deadline exceeded
  # Container RUNNING, port closed, forever. Doubling the CPU is the fix --
  # IN A NORMAL ACCOUNT.
  #
  # ON THE KODEKLOUD PLAYGROUND THIS SIZE IS REAPED. Five minutes after the
  # 2 vCPU task started, CloudTrail shows UpdateService(desiredCount=0),
  # StopTask and DeleteService from
  #   assumed-role/OrganizationAccountAccessRole/ConfigRuleCheckerSession*
  # -- a compliance job, not an SCP: the apply succeeds and the service
  # vanishes later. The 1 vCPU task ran 30 minutes untouched. So on the
  # playground Artifactory runs on EKS instead (ci/artifactory/), and this
  # stack is the ECS example rather than the live one.
  cpu    = "2048"
  memory = "8192"

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
      # REQUIRED with Derby on current versions. Without it the task sits
      # RUNNING forever while the app inside is dead -- the only trace is in a
      # log this task cannot ship (no execution role, so no awslogs):
      #   java.lang.IllegalStateException: Cannot start the application with a
      #   database other than PostgreSQL.
      # Found by running the same image as a pod on EKS and reading kubectl logs.
      { name = "JF_SHARED_DATABASE_ALLOWNONPOSTGRESQL", value = "true" },
      { name = "JF_SHARED_SECURITY_MASTERKEY", value = random_id.master_key.hex },
      { name = "JF_SHARED_SECURITY_JOINKEY", value = random_id.join_key.hex },
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
