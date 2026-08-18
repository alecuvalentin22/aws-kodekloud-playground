terraform {
  backend "s3" {
    key          = "platform-lab/eks-module/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
