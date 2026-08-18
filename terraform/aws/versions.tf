terraform {
  required_version = ">= 1.10" # use_lockfile (S3-native locking) landed in 1.10
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    local  = { source = "hashicorp/local", version = "~> 2.4" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" {
  region = var.region
}
