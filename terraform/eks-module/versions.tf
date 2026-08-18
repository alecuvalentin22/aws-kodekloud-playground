terraform {
  required_version = ">= 1.10"
  required_providers {
    # AWS provider 6.x, NOT the ~> 5.0 the rest of this repo uses.
    #
    # terraform-aws-modules/eks v21 requires >= 6.0.0, and pinning 5.x here
    # fails at init with:
    #
    #   no available releases match the given constraints ~> 5.0, >= 6.0.0
    #
    # Each root module has its own lock file, so they can legitimately differ.
    # This is the usual cost of adopting a large community module: it drags its
    # own provider floor along with it, and on a shared repo that decision
    # belongs to whoever maintains the other root modules too.
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" { region = var.region }
