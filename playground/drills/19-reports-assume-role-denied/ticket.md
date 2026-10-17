From: Mira (reports team)                                      #help-platform

  our daily-report service (reports-api, namespace: reports) cannot read its
  CSV from S3 any more. it worked until the end of last week. every attempt
  ends in AccessDenied.

  we checked IAM twice: the role drill19-reports-reader has a policy that
  allows s3:GetObject and s3:ListBucket on our bucket, and the bucket is the
  right one. nobody changed the policy. so why is S3 refusing a role that is
  allowed to read?

  the finance close report is due this afternoon.

From: Platform on-call                                         #platform-changes

  no platform changes since Thursday. do not give the node role access to the
  bucket "just to get it working": that hands the bucket to every pod on the
  node.
