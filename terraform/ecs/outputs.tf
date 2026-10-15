output "how_to_find_the_url" {
  description = "Fargate tasks get a fresh public IP on every start, so it is looked up, not output."
  value       = "aws ecs list-tasks --cluster ${aws_ecs_cluster.this.name} --service-name artifactory, then describe the task's ENI for its public IP; port 8082"
}
