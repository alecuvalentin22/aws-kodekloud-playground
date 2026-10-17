ROOT CAUSE
  A teammate's commit on main changed the pull_request trigger from
  `paths-ignore: ["**.md", "docs/**"]` to `paths: ["src/**", "tests/**"]`, a
  layout copied from another repo. This repo's code is in service/, so no PR that
  changes service/ matches, and GitHub starts no workflow run: no checks, no
  "failed", just silence. Pushes to main were unaffected because the push trigger
  has no path filter. The PR is not broken; the trigger is.

FIX
  1. Branch from main, fix the trigger: either put paths-ignore back, or make
     `paths:` list what really matters (service/**, requirements.txt, Dockerfile,
     .github/workflows/**). Open a PR; its own checks prove the fix.
  2. Merge it. Then give Sam's PR a new event: "Update branch", or close and reopen
     it, or push to it. The workflow file used for a pull_request run comes from
     the PR's merge result, so Sam's PR now picks up the fixed trigger.
  NOT: `on: [push, pull_request]` with every filter removed (docs-only PRs burn
  minutes again; the repo had paths-ignore for a reason). NOT: pull_request_target.

WHY pull_request_target IS THE WRONG FIX
  It runs the workflow from the BASE branch with a read/write GITHUB_TOKEN and
  access to secrets, even for PRs from forks. People reach for it because it "just
  runs", then add `actions/checkout` with ref: ${{ github.event.pull_request.head.sha }}
  and execute the PR's code, which hands the base repo's secrets to whoever opened
  the PR (the "pwn request"). It exists for trusted jobs that only label or comment.

WHAT STOPS IT RECURRING
  Workflow changes get a reviewer who knows triggers (CODEOWNERS on
  .github/workflows/). A required status check means a PR whose CI never started is
  shown as "Expected" instead of passing silently. A path filter + required check
  is a trap, though: a PR that skips the workflow can never merge. That is drill 32.

SAY THIS IN THE INTERVIEW
  "No checks at all means nothing started, so I looked at the trigger, not the
  jobs. A path filter someone copied from another repo meant none of this repo's
  PRs matched, and filtered-out PRs get no run, not a failed one. I fixed the
  trigger in a PR (which tested itself), gave the stuck PR a new event, and kept the
  docs-only paths-ignore. I didn't use pull_request_target: it runs with the base
  repo's secrets and write token, which is the wrong trust boundary for code from
  a PR."
