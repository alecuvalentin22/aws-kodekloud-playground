#!/usr/bin/env bash
# Builds the "infra repo" with count-indexed buckets, applies it, then makes
# Mia's edit WITHOUT applying it.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"
d="$WORK/infra"
rm -rf "$d" && mkdir -p "$d"
cat > "$d/main.tf" <<'HCL'
terraform {
  required_version = ">= 1.5"
  # Local state for the playground. In the EKS lab this is the S3 backend
  # with use_lockfile -- platform-lab drills/10.
  backend "local" {}
}

variable "teams" {
  type        = list(string)
  description = "Teams that get an artifact bucket."
}

# Stand-in for aws_s3_bucket. In AWS, changing a bucket's name forces a
# replacement (destroy + create = data gone); triggers_replace does the same.
resource "terraform_data" "artifact_bucket" {
  count            = length(var.teams)
  triggers_replace = "acme-${var.teams[count.index]}-artifacts"
  input = {
    bucket = "acme-${var.teams[count.index]}-artifacts"
    team   = var.teams[count.index]
  }
}

output "buckets" {
  value = terraform_data.artifact_bucket[*].output.bucket
}
HCL
printf 'teams = ["payments", "growth", "search"]\n' > "$d/terraform.tfvars"
cd "$d"
terraform init -input=false >/dev/null
terraform apply -input=false -auto-approve >/dev/null
# Remember each bucket's identity: a replaced resource gets a new id.
terraform state pull | jq -r '.resources[] | select(.name=="artifact_bucket") | .instances[] | "\(.attributes.input.value.team // .attributes.input.team) \(.attributes.id)"' \
  > "$STATE/drill08.ids"
printf 'teams = ["payments", "search"]\n' > "$d/terraform.tfvars"
