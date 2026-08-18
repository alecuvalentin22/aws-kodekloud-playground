# ---------------------------------------------------------------------------
# Managed PostgreSQL (RDS), alongside the self-managed PostgreSQL on es-01.
#
# Running BOTH is the point. Same engine, same SQL, same roles and grants --
# but the operational surface is completely different, and being able to
# articulate that difference is what the "relational databases" line on the JD
# is actually asking for:
#
#   on EC2                        on RDS
#   ----------------------------- -----------------------------------------
#   you patch the OS and PG       AWS does, in a maintenance window you pick
#   you write the backup cron     automated backups + PITR, retention in days
#   you edit postgresql.conf      parameter groups, some settings need a reboot
#   you have superuser            you do NOT -- rds_superuser is not superuser
#   pg_hba.conf controls access   security groups do
#   restore = your own runbook    restore = a NEW instance from a snapshot
#
# That "no superuser" line is the one that surprises people. On RDS you cannot
# CREATE EXTENSION for anything outside the supported list, cannot read the
# filesystem, and cannot install untrusted languages.
# ---------------------------------------------------------------------------

# Generated, never typed, never committed. Terraform writes it to state -- which
# is exactly why the state bucket is encrypted and locked down in
# terraform/bootstrap. State is a secrets file that happens to look like JSON.
resource "random_password" "rds" {
  count = var.create_rds ? 1 : 0

  length  = 24
  special = true
  # RDS rejects these in a master password.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# RDS is placed by SUBNET GROUP, not by subnet: you hand it a set of subnets in
# different AZs and AWS picks. That set is also what makes a Multi-AZ failover
# possible later -- the standby needs somewhere to live.
resource "aws_db_subnet_group" "lab" {
  count = var.create_rds ? 1 : 0

  name       = "${var.prefix}-db-subnets"
  subnet_ids = data.aws_subnets.default.ids

  tags = { Name = "${var.prefix}-db-subnets" }
}

# A SEPARATE security group from the instances, whose only ingress rule is
# "port 5432 from the lab security group". Not from a CIDR -- from a GROUP.
#
# That is the AWS idiom worth showing: the rule references identity rather than
# addresses, so it keeps working when instances are replaced and IPs change,
# and nothing outside the lab can reach the database even inside the same VPC.
resource "aws_security_group" "rds" {
  count = var.create_rds ? 1 : 0

  name        = "${var.prefix}-rds-sg"
  description = "Postgres from the lab instances only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Postgres from lab instances"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lab.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-rds-sg" }
}

resource "aws_db_instance" "postgres" {
  count = var.create_rds ? 1 : 0

  identifier     = "${var.prefix}-pg"
  engine         = "postgres"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class

  allocated_storage = var.rds_allocated_storage
  storage_type      = "gp2"
  storage_encrypted = true

  db_name  = var.postgres_app_db
  username = var.rds_master_username
  password = random_password.rds[0].result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.lab[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  # No public endpoint. Ansible reaches it from es-01, inside the VPC, which is
  # also how a real application would.
  publicly_accessible = false

  # Single-AZ: Multi-AZ doubles the cost and the playground will not allow it.
  # Worth knowing what it buys -- a synchronous standby in another AZ and an
  # automatic DNS failover, NOT a read replica (that is a different feature).
  multi_az = false

  # Automated backups. 1 day is the minimum that still enables point-in-time
  # recovery; 0 disables PITR entirely, which is the wrong default to learn.
  backup_retention_period = var.rds_backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # Lab settings. In production: skip_final_snapshot = false, deletion_protection
  # = true, and you accept that destroy is deliberately hard.
  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true

  # The master password lives in state, so Terraform would otherwise show a diff
  # every time the generator produced a new value. This is also the argument for
  # manage_master_user_password = true (AWS stores it in Secrets Manager and
  # rotates it) -- unavailable in the playground, since Secrets Manager is not
  # in the permitted service list.
  lifecycle {
    ignore_changes = [password]
  }

  tags = {
    Name = "${var.prefix}-pg"
    Role = "rds"
  }
}
