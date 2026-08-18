variable "region" {
  description = "KodeKloud playground is pinned to us-east-1. Do not change it there."
  type        = string
  default     = "us-east-1"
}

variable "prefix" {
  type    = string
  default = "andrei-lab"
}

variable "instance_type" {
  description = "KodeKloud allows t1/t2/t3 nano|micro|small|medium only. t3.medium = 2 vCPU / 4 GB, which is the minimum sane size for an Elasticsearch node."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_gb" {
  description = "KodeKloud caps gp2 at 30 GB."
  type        = number
  default     = 30
}

variable "volume_type" {
  description = "gp2 on KodeKloud. gp3 is cheaper and faster in a real account."
  type        = string
  default     = "gp2"
}

variable "es_node_count" {
  type    = number
  default = 3
}

variable "create_k8s_node" {
  description = "Set false to stay under the 5-instance playground cap if you need headroom."
  type        = bool
  default     = true
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "my_ip_cidr" {
  description = "Your public IP as a /32. Find it with: curl -s ifconfig.me"
  type        = string
}

variable "data_volume_gb" {
  description = <<-EOT
    Size of the dedicated EBS data volume attached to each Elasticsearch node.
    Set to 0 to skip the extra volumes and keep data on the root disk (useful if
    the playground's EBS quota is tight -- 3 nodes x 30 GiB root already spends
    90 GiB before these).

    Deliberately small: drills/03 fills this until Elasticsearch hits the
    flood-stage watermark, and 10 GiB gets there in seconds.
  EOT
  type        = number
  default     = 10

  validation {
    condition     = var.data_volume_gb == 0 || var.data_volume_gb >= 4
    error_message = "Use 0 to disable, or at least 4 GiB -- Elasticsearch refuses to start with almost no free space."
  }
}

variable "data_volume_iops" {
  description = "gp3 only. Ignored for gp2, where IOPS are a function of size (3 IOPS/GiB)."
  type        = number
  default     = 3000
}

variable "data_volume_throughput" {
  description = "gp3 only, MiB/s. Ignored for gp2."
  type        = number
  default     = 125
}

# --- RDS ---------------------------------------------------------------------

variable "create_rds" {
  description = <<-EOT
    Provision managed PostgreSQL alongside the self-managed one on es-01.
    Set false to skip it -- RDS takes 5-10 minutes to become available, which is
    a meaningful slice of a 3-hour playground session.
  EOT
  type        = bool
  default     = true
}

variable "rds_instance_class" {
  description = "db.t3.micro is Free Tier eligible and inside the playground's allowed classes."
  type        = string
  default     = "db.t3.micro"
}

variable "rds_engine_version" {
  description = "Major version only -- AWS resolves the current minor. Pinning the full version means fighting Terraform every time AWS patches."
  type        = string
  default     = "16"
}

variable "rds_allocated_storage" {
  description = "GiB. 20 is the RDS minimum for gp2."
  type        = number
  default     = 20
}

variable "rds_master_username" {
  description = "NOT 'postgres' -- that name is reserved by RDS and rejected."
  type        = string
  default     = "pgadmin"
}

variable "rds_backup_retention_days" {
  description = "1-35. Zero disables point-in-time recovery entirely."
  type        = number
  default     = 1
}

variable "postgres_app_db" {
  description = "Initial database name. Kept in sync with the Ansible variable of the same name so both PostgreSQLs hold the same schema."
  type        = string
  default     = "appdb"
}

variable "create_rancher_node" {
  description = <<-EOT
    A second Kubernetes node running RKE2, dedicated to Rancher.

    Two reasons it exists:
      1. drills/07 compares Rancher on k3s vs RKE2, which needs both.
      2. A single t3.medium cannot hold Rancher AND Keycloak. Separate boxes
         let the full stack run at once.

    3 ES + k3s + this = 5 instances, the playground's hard cap.
  EOT
  type        = bool
  default     = false
}

variable "service_source_ranges" {
  description = <<-EOT
    Who may reach the WEB SERVICES (Kibana, MinIO, Elasticsearch HTTP, Kong,
    Keycloak, Rancher). Defaults to [] which means "same as my_ip_cidr".

    Set ["0.0.0.0/0"] to share links with someone else. Understand what that
    exposes before you do:

      - Elasticsearch runs with elastic_security_enabled = false. It is an
        UNAUTHENTICATED database on port 9200. Anyone can read, modify or
        delete every index. Open Elasticsearch instances are found by internet
        scanners within minutes and are a standing ransomware target.
      - Rancher and Keycloak admin consoles use passwords that default to the
        literal string "CHANGE-ME-IN-VAULT", which is documented in this
        public repository. That is cluster-admin for anyone who finds the IP.

    Acceptable for a throwaway playground that expires in hours. Never for
    anything that outlives the session, and never with real data.

    SSH is deliberately NOT covered by this and stays locked to my_ip_cidr.
  EOT
  type        = list(string)
  default     = []
}
