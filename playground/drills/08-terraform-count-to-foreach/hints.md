Run `terraform plan` yourself in ~/platform-playground/infra and read the
ADDRESSES, not the summary line. What is at [0], [1] and [2] before the edit,
and what would be there after?
---
With count, a resource's identity is its position in the list. Remove the
middle element and everything after it shifts down one: [1] goes from
"growth" to "search" (name change = replace), and [2] disappears.
Identity should be the team name. That is what for_each gives you.
---
Switch to for_each = toset(var.teams), and tell Terraform where the existing
objects went with moved blocks, e.g.
  moved {
    from = terraform_data.artifact_bucket[0]
    to   = terraform_data.artifact_bucket["payments"]
  }
Plan BEFORE apply: the only destroy should be ["growth"]. (Fix `output` too.)
