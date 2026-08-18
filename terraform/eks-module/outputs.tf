output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}
