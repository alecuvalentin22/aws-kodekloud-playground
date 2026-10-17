ROOT CAUSE
  Two separate things stood between Sam's branch and a build, one behind the
  other. The scan log (job > Scan Multibranch Pipeline Log) shows both:

  1. Jenkins was not LOOKING at the branch. Jordan had set "Filter by name
     (with wildcards)" to `main release/*` in the branch source's Behaviours.
     The log (verbatim, local playground):
         Checking branches...
           Checking branch main
               ‘Jenkinsfile’ found
             Met criteria
         Processed 2 branches
     Two branches processed, one checked: the other was filtered out BEFORE
     any check, so it is never mentioned. "Processed N branches" with fewer
     "Checking branch" lines than N is the tell.
  2. Once the filter is widened, the log says what is wrong with the branch:
           Checking branch feature/refund-endpoint
               ‘Jenkinsfile’ not found
             Does not meet criteria
     The branch was cut on a Mac and carries `jenkinsfile`. Gitea and the
     agent are Linux: file names are case-sensitive, the job's Script Path is
     `Jenkinsfile`, so the branch is "not a pipeline" and gets no job at all.
     (No job, not a red job: a branch that does not meet criteria is simply
     not created. A red job means the Jenkinsfile was found.)

FIX
  1. Job > Configure > Branch Sources > Git > Behaviours > Filter by name:
     include `main feature/* fix/* release/*`. Saving re-indexes straight away.
  2. Fix THE BRANCH, not the job:
         git switch feature/refund-endpoint
         git mv jenkinsfile Jenkinsfile        # on a Mac: git mv jenkinsfile tmp && git mv tmp Jenkinsfile
         git commit -m "Jenkinsfile: right case" && git push
     (and `git config core.ignorecase false` so it does not happen again).
  The next scan finds the branch, creates its job and builds it.

WHAT WORKS BUT HURTS (the check penalizes or refuses these)
  - Changing the job's Script Path to `jenkinsfile`: the branch builds, and
    main now says "‘jenkinsfile’ not found / Does not meet criteria". The check
    refuses it. With the default orphaned-item strategy, a main that stops
    meeting criteria can even be pruned.
  - A separate single-branch job for Sam: green today, and the next person's
    branch has the same problem. That is the world Jordan was cleaning up.
  - Merging the branch to main to get a build: skips the PR the CI was for.
  - Removing the filter entirely: fixes this ticket and brings back the 140
    stale jobs. A filter is fine; a filter nobody told the team about is not.

WHAT STOPS IT RECURRING
  - The job is defined in code (JCasC + Job DSL). Jordan's UI edit would have
    vanished at the next controller restart, taking Sam's fix with it. The
    durable change is in the job definition in git (branch source traits /
    the Job DSL), reviewed like any other change; an edit made only in the UI
    is a bug waiting for a restart. Say that to Jordan, kindly.
  - Prune stale jobs with the orphaned item strategy (days/number to keep) or
    a branch-deleted-in-git cleanup, not by hiding branches.
  - Webhooks (Gitea -> Jenkins) for instant indexing; here the job polls every
    minute (periodic folder trigger) because the lab has no inbound webhook.

SAY THIS IN THE INTERVIEW
  "A multibranch job has two questions for every branch: do I look at it, and
  does it meet my criteria, meaning a file at the Script Path. 'No job' means
  one of those said no. I read the scan log first: it processed two branches
  but only checked one, so a name filter was hiding the branch. After
  widening it the log said the Jenkinsfile was not found, which was a
  lowercase file name from a Mac. I fixed the branch rather than the job,
  because the Script Path is shared by every branch. And I told Jordan the
  filter had been changed in the UI only, so a restart would have undone it:
  the job is defined in code, the change belongs there."

  Related: drill 45 (a push is seen but never built: NoTriggerBranchProperty),
  the exercise `exercises/jenkins-job-types` (multibranch from scratch).
