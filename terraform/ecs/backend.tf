# Same state bucket as the other stacks, its own key -- so destroying this does
# not touch EKS, and vice versa. Initialise with: ../../scripts/tf-init.sh ecs
terraform {
  backend "s3" {
    key          = "platform-lab/ecs/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
