ROOT CAUSE
  count keys resources by list index. Removing "growth" (index 1) shifts
  "search" from [2] to [1]; [1]'s name changes from growth to search, which
  forces replacement, and [2] is destroyed. Plan: 1 to add, 2 to destroy --
  and one of those destroys is the search bucket with its data.

FIX
  resource "terraform_data" "artifact_bucket" {
    for_each         = toset(var.teams)
    triggers_replace = "acme-${each.key}-artifacts"
    input            = { bucket = "acme-${each.key}-artifacts", team = each.key }
  }
  moved {
    from = terraform_data.artifact_bucket[0]
    to   = terraform_data.artifact_bucket["payments"]
  }
  # ...the same for [1] -> ["growth"] and [2] -> ["search"]
  output "buckets" {
    value = [for b in terraform_data.artifact_bucket : b.output.bucket]
  }

  Plan: 0 to add, 0 to change, 1 to destroy -- ["growth"]. Apply. (On older
  Terraform without `moved`: terraform state mv, which is not reviewable.)

WHAT STOPS IT RECURRING
  for_each for anything with an identity; count only for "N identical
  things". Plan in CI on every PR, posted to the PR, and fail the check when a
  plan destroys or replaces something not explicitly allowed. In AWS also:
  prevent_destroy on buckets with data, and S3 versioning.

SAY THIS IN THE INTERVIEW
  "The developer did the right thing -- ran plan before applying -- and the plan
  told the truth: count ties identity to list position. I moved the resources
  to for_each keyed by team, with `moved` blocks so the migration itself is in
  code and shows up in the PR, and the plan went from 2 destroys to exactly
  one. That's what 'Terraform changes should be reviewable and safe' means to
  me: the plan is the review artifact, and it should say only what you meant."
