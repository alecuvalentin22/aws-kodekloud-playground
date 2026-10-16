From: Mia (search team)                                       #help-platform

  the growth team was shut down, so I removed "growth" from `teams` in
  ~/platform-playground/infra/terraform.tfvars and ran plan before opening the
  PR. it wants to DESTROY the search bucket too?? we have 2 years of build
  artifacts in there. I haven't applied anything. what is it doing, and can
  you make it delete only growth's bucket?

  (The resources are terraform_data stand-ins for aws_s3_bucket -- a bucket
  name forces replacement in AWS the same way triggers_replace does here.
  Everything runs locally; there is no AWS account behind it.)
