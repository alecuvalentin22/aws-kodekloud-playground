ROOT CAUSE
  Terraform plans from config + state. The bucket existed in AWS and in main.tf,
  but not in the state, so the plan said "create". Nothing was wrong with the
  bucket; it had simply never been ADOPTED. apply fails with
  "creating S3 Bucket: BucketAlreadyExists" (measured live in us-east-1; elsewhere
  it can read BucketAlreadyOwnedByYou). The config itself was also wrong:
  it was written from memory -- one tag instead of four, versioning "Suspended"
  on a bucket where it is Enabled.

FIX
  1. Do not delete the bucket. "It's only an export" is a claim to check:
       aws s3api list-object-versions --bucket <name>
       aws s3api list-buckets --query "Buckets[?Name=='<name>']"   (note CreationDate)
     Delete-and-recreate gives a new bucket with the same name and none of the data.
  2. Import both resources. Two import blocks in the config (Terraform >= 1.5):
       import { to = aws_s3_bucket.ledger_exports             id = "<bucket name>" }
       import { to = aws_s3_bucket_versioning.ledger_exports  id = "<bucket name>" }
     (or `terraform import aws_s3_bucket.ledger_exports <name>` and the same for
     the versioning resource). The ID of both is just the bucket name.
  3. terraform plan. It shows the import AND the drift: tags to remove (env,
     retention, platform-lab-drill) and versioning Enabled -> Suspended. DO NOT
     apply that. It would change a production-looking bucket to match a guess.
     Edit the code until it states reality: all four tags, status = "Enabled".
  4. Plan again: "2 to import, 1 to change". The one change left is
     force_destroy = false, a Terraform-only attribute that AWS has no notion of,
     so an import always adds it. Then apply: it creates and modifies nothing in
     AWS, it only writes the state. A last plan says "No changes".
  The import blocks may stay in the config afterwards: once imported they are
  no-ops, and they document how the resource came to be. Remove them in a later
  cleanup if you like; Terraform does not care.
  NOT: delete the bucket and let Terraform make it (the data is gone);
  `lifecycle { ignore_changes = all }` (a clean plan that hides the differences);
  applying the first plan (strips tags, suspends versioning).

WHAT STOPS IT RECURRING
  Anything created by hand in an incident gets a follow-up ticket "adopt into
  Terraform" with the checklist: import first, then make plan empty, then apply.
  `terraform plan -generate-config-out=generated.tf` can write a first draft of the
  config from the real resource -- still read it. Make plan part of the PR check,
  and consider an SCP/permission boundary so only the pipeline role can create
  buckets outside Terraform.

SAY THIS IN THE INTERVIEW
  "Terraform was not wrong, it did not know the bucket. I refused delete-and-recreate,
  because the bucket held data and re-creating gives you the same name and an empty
  bucket; I noted its creation date and object checksum first so I could prove
  afterwards it was the same one. I imported both the bucket and its versioning
  resource with import blocks, read the plan that followed -- it wanted to strip
  tags and suspend versioning, because the config had been written from memory --
  and fixed the code, not the bucket, until the plan was empty. Only then did I
  apply, which was a no-op that recorded the state. I never used ignore_changes to
  make the plan green."
