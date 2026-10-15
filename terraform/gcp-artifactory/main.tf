# ---------------------------------------------------------------------------
# STATUS: WRITTEN, NOT RUN. terraform validate passes; no GCP account was
# available.
#
# JFrog Artifactory OSS on one GCE VM, running as a single Docker container.
#
# Why it is here and not on the AWS playground: Artifactory OSS 7.161.26 never
# got to a running state there.
#   - Fargate, 1 vCPU: the router timed out waiting for the access service,
#     which took 364 s to start.
#   - Fargate, 2 vCPU: the playground's compliance job (ConfigRuleChecker)
#     deleted the service 5 minutes after apply.
#   - EKS, t3.medium: OOMKilled at a 3Gi limit. The image runs five JVMs in one
#     container.
# An e2-standard-2 (2 vCPU / 8 GiB) has none of those limits.
#
# Why a plain VM: it is one vendor container with no scaling story. GKE would
# be a whole cluster for one pod. Cross-cloud is fine for a lab -- Jenkins on
# EKS reaches it over the internet on port 8082.
#
# Usage (the Compute Engine API must be enabled on the project):
#   terraform -chdir=terraform/gcp-artifactory init && \
#     terraform -chdir=terraform/gcp-artifactory apply -var project=<id>
#
# State is local on purpose. This is a throwaway, so no remote backend.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
}

variable "project" {
  description = "GCP project ID to deploy into."
  type        = string
}

variable "region" {
  description = "GCP region."
  type        = string
  default     = "europe-west3"
}

variable "zone" {
  description = "GCP zone for the VM."
  type        = string
  default     = "europe-west3-a"
}

variable "machine_type" {
  # 2 vCPU / 8 GiB. 1 vCPU was too slow for access to start inside the
  # router's timeout, and 3Gi was not enough memory for the five JVMs.
  description = "GCE machine type."
  type        = string
  default     = "e2-standard-2"
}

variable "artifactory_version" {
  description = "Tag of releases-docker.jfrog.io/jfrog/artifactory-oss."
  type        = string
  default     = "7.161.26"
}

variable "allowed_cidrs" {
  # Open to the world because this is a throwaway lab and the Jenkins agents on
  # EKS egress through NAT IPs that change with the cluster. For anything that
  # lives longer, narrow this to those NAT IPs and your own address.
  description = "Source CIDRs allowed to reach Artifactory on tcp/8082."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Artifactory refuses to start without these two keys (see the startup script).
# Generating them here keeps them stable across VM recreation as long as the
# state survives. They end up in plain text in instance metadata and in state,
# which is fine for a lab; anywhere else they belong in Secret Manager.
resource "random_id" "master_key" {
  byte_length = 32
}

resource "random_id" "join_key" {
  byte_length = 32
}

resource "google_compute_firewall" "artifactory" {
  name    = "allow-artifactory-8082"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["8082"]
  }

  source_ranges = var.allowed_cidrs
  target_tags   = ["artifactory"]
}

resource "google_compute_instance" "artifactory" {
  name         = "artifactory"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["artifactory"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      # The Docker volume lives on the boot disk, so this is also the
      # artifact storage. 30 GB is plenty for a lab.
      size = 30
      type = "pd-balanced"
    }
  }

  network_interface {
    network = "default"

    # Empty block = ephemeral public IP. It changes if the VM is stopped and
    # started, so re-read the url output after that.
    access_config {}
  }

  # Startup scripts run on every boot, not just the first one. The script is
  # written so a reboot is a no-op: --restart unless-stopped already brings the
  # container back.
  #
  # Inside this heredoc Terraform interpolates ${...}; a shell variable has to
  # be written as $${...} so it reaches bash untouched.
  metadata = {
    startup-script = <<-EOT
      #!/bin/bash
      set -euo pipefail

      if ! command -v docker >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
        systemctl enable --now docker
      fi

      # Already created on an earlier boot: nothing to do.
      if docker container inspect artifactory >/dev/null 2>&1; then
        exit 0
      fi

      docker volume create artifactory_data

      args=(
        --name artifactory
        --restart unless-stopped
        -p 8082:8082
        # The default nofile limit is too low; Artifactory warns and can fail
        # under load without this.
        --ulimit nofile=32000:40000
        -v artifactory_data:/var/opt/jfrog/artifactory

        # Embedded Derby instead of a separate PostgreSQL. Fine for one user.
        -e JF_SHARED_DATABASE_TYPE=derby
        # Without this: "Cannot start the application with a database other
        # than PostgreSQL."
        -e JF_SHARED_DATABASE_ALLOWNONPOSTGRESQL=true

        # Without these two: "Master key is missing ..." and the services give
        # up after a 60 seconds timeout.
        -e JF_SHARED_SECURITY_MASTERKEY=${random_id.master_key.hex}
        -e JF_SHARED_SECURITY_JOINKEY=${random_id.join_key.hex}
      )

      docker run -d "$${args[@]}" \
        releases-docker.jfrog.io/jfrog/artifactory-oss:${var.artifactory_version}
    EOT
  }
}

output "url" {
  description = "Artifactory UI and API base URL."
  value       = "http://${google_compute_instance.artifactory.network_interface[0].access_config[0].nat_ip}:8082"
}

output "note" {
  description = "What to expect after apply."
  value       = <<-EOT
    A cold start takes several minutes: the image pull, then five JVMs starting
    one after another. It is ready when /artifactory/api/system/ping returns OK.
    First login is admin / password, and Artifactory forces a password change.
  EOT
}
