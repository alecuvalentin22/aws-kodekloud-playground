output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "node_group_status" {
  description = "null when create_node_group = false (the playground denies eks:CreateNodegroup)."
  value       = var.create_node_group ? aws_eks_node_group.this[0].status : null
}

output "kubeconfig_command" {
  description = "EKS does not hand you a kubeconfig file. The CLI mints one, and the credential inside it is an IAM token that expires -- it is not a static cert like k3s writes."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this.name} --alias ${aws_eks_cluster.this.name}"
}

output "next_steps" {
  value = <<-EOT

    ${aws_eks_cluster.this.name} is up (Kubernetes ${aws_eks_cluster.this.version}).

      aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this.name} --alias ${aws_eks_cluster.this.name}
      kubectl --context ${aws_eks_cluster.this.name} get nodes

      # a test workload sized to fit the playground's per-pod caps
      kubectl --context ${aws_eks_cluster.this.name} apply -f manifests/test-workload.yaml
      kubectl --context ${aws_eks_cluster.this.name} -n eks-test rollout status deploy/hello

    WHEN YOU ARE DONE:  terraform destroy
    (the node group must go before the cluster -- Terraform orders that for you)
  EOT
}
