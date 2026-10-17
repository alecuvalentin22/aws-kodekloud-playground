From: Sam (payments team)                                    #help-platform

  during last week's incident I made an S3 bucket by hand to get the ledger
  export out (it has versioning on and the export inside). Afterwards I wrote
  the Terraform for it so we can manage it properly. But `terraform plan` says
  it wants to CREATE the bucket, and apply fails because it already exists.

  Can I just delete the bucket and let Terraform make it? It's only an export.
  (root: ~/platform-playground-aws/tf-import, creds: . ./aws-env.sh)
