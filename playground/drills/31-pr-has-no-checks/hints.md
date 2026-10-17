"No checks at all" is different from "checks failed". Nothing started, so the
question is which `on:` trigger decided not to start it. Read the workflow as it
is on main, then look at what Sam's PR actually changed:
  git -C ~/platform-playground-github/playground-demo-api pull && git log --oneline -5 -- .github
---
Look at the `pull_request:` block in .github/workflows/ci.yml, and at `git log -p`
for that file. Which files does it say a PR must touch to run? Where does this
repo keep its code? (Branch filters and path filters both silently skip a run.)
---
Fix the trigger in a PR of your own (a PR runs the workflow file from ITS merge
result, so your fix PR shows whether it works). After it merges, Sam's PR needs a
new event to start: update the branch, or close and reopen it. Do NOT "fix" it
with pull_request_target, and do not delete the filters: docs-only PRs
shouldn't burn runner minutes.
