# Same bucket as the main stack, DIFFERENT key. That is the whole reason EKS is
# a separate root module rather than more resources in terraform/aws:
#
#   - separate state means `terraform destroy` here tears down the cluster
#     without touching the Elasticsearch lab, and vice versa
#   - a slow resource (an EKS cluster takes ~10 minutes, a node group another
#     ~3) is not in the critical path of every plan you run on the main stack
#   - blast radius: a mistake in one cannot corrupt the other's state
#
# Initialise it with:  ../../scripts/tf-init.sh eks
terraform {
  backend "s3" {
    key          = "platform-lab/eks/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
