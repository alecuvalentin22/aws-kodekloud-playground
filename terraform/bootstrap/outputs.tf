output "state_bucket" {
  description = "Feed this to the other root modules: terraform init -backend-config=\"bucket=$(terraform -chdir=../bootstrap output -raw state_bucket)\""
  value       = aws_s3_bucket.state.id
}

output "region" {
  value = var.region
}

output "init_command" {
  value = <<-EOT

    Now initialise the main stack against this bucket:

      cd ../aws
      terraform init -backend-config="bucket=${aws_s3_bucket.state.id}"

    Or just run ../../scripts/tf-init.sh, which does that for you.
  EOT
}
