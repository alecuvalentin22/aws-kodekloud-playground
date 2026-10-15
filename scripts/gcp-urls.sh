#!/usr/bin/env bash
# Print the URLs of the GCP-playground services (docs/kodekloud-gcp-limits.md).
# Reads local Terraform state only; no gcloud call, no token needed.
#
# The VM's IP is ephemeral: it changes if the VM is stopped and started, and
# the output reflects that only after a `terraform apply -refresh-only`.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

url_of() { # <module dir> <output name>
  local dir="$ROOT/terraform/$1"
  if [[ ! -f "$dir/terraform.tfstate" ]]; then
    echo "not deployed (no state in terraform/$1)"
    return
  fi
  terraform -chdir="$dir" output -raw "$2" 2>/dev/null || echo "no '$2' output in terraform/$1"
}

echo "Artifactory: $(url_of gcp-artifactory url)   (admin / admin)"
echo "Backstage:   $(url_of gcp-backstage url)"
