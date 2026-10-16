terraform {
  # Local state, kept OUT of the repo: init with
  #   -backend-config=path=$HOME/.local/state/platform-lab-playground/semaphore.tfstate
  backend "local" {}
  required_version = ">= 1.5.0"
  required_providers {
    semaphoreui = {
      source  = "semaphoreui/semaphore"
      version = "= 0.3.9"
    }
  }
}

provider "semaphoreui" {
  api_base_url = var.api_base_url
  # Read from SEMAPHOREUI_API_TOKEN in the environment. Never put it in tfvars.
}

variable "api_base_url" {
  type        = string
  description = "Semaphore API URL (include /api). The same instance gcp-setup manages."
  default     = "http://127.0.0.1:3000/api"
}

variable "lab_path_in_container" {
  type        = string
  description = "Where compose.override.yaml mounts the platform-lab checkout."
  default     = "/platform-lab"
}
