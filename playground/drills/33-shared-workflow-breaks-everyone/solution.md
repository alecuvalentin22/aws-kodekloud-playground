ROOT CAUSE
  Both repos call the shared workflow with `uses: .../python-lint.yml@main`, a branch.
  A commit on the shared repo's main added a REQUIRED input (`lint-config`) with no
  default. GitHub validates `workflow_call` inputs when it loads the caller's
  workflow, so every caller that does not pass it fails at startup ("Invalid workflow
  file ... Input lint-config is required, but not provided"), before any job runs.
  The blast radius of a shared workflow is every repo that follows its branch. Same
  failure as drill 07 (the Jenkins shared library), different CI.

FIX, IN ORDER
  1. Stop the bleeding in the shared repo, as a new commit: `git revert <sha>` and
     push (or give the input a default). NOT a force-push: main is shared.
  2. Tell the teams, with an ETA, in the channel they asked in.
  3. Release it: tag the fixed commit (v1.0.1). Never move or delete an existing tag:
     someone may already be pinned to v1.0.0, and a moved tag changes what they run
     without any commit of their own.
  4. Make it unrepeatable: change each caller to `@v1.0.1` (or a full SHA). A caller
     pinned to a tag is immune to main. demo-api's main is protected, so that change
     goes through a pull request (as it should). Roll future versions out one canary
     repo first.
  5. Re-land the new input properly: optional first (accept both), release v1.1.0,
     deprecate, then require it in a major version.

WHAT STOPS IT RECURRING
  Callers pin tags or SHAs; Dependabot/Renovate bumps `uses:` refs through PRs, so a
  new release reaches repos on purpose; the shared repo has its own CI that calls its
  workflows from a test caller before a tag is cut; tag protection (a ruleset on
  `v*`) so released tags cannot be moved. This playground leaves the shared repo
  unprotected so you CAN make those mistakes; the check looks for them.

SAY THIS IN THE INTERVIEW
  "A shared workflow is a platform with N customers, so a breaking change is an outage
  for N repos. Nobody had pushed, two repos went red at once, so I looked at what they
  share and found a new required input on the shared main. I reverted it forward, with
  a new commit, because main is shared, then tagged a release and pinned the callers
  to it so one commit can't reach every repo at once again. The breaking change
  comes back later as 'optional, then required in a major'."
