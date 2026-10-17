ROOT CAUSE
  Jordan added the branch property "Suppress automatic SCM triggering"
  (NoTriggerBranchProperty) to demo-api's branch source, by hand in the UI, to
  keep feature-branch pushes off the agents. The property does not stop Jenkins
  from LOOKING: branch indexing still runs every minute and sees every commit.
  It stops Jenkins from SCHEDULING. The scan log says so, in plain words:
    Checking branch main
        ‘Jenkinsfile’ found
        Met criteria
    Changes detected: main (<old sha> → <new sha>)
    Did not schedule build for branch: main
  Build Now still works because a person is not an "automatic SCM trigger".
  That is why the pipeline looked fine and the trigger looked broken: they
  are two different things, and only the trigger was changed.

HOW BUILDS GET STARTED HERE (worth saying out loud)
  There is no webhook in this playground. The multibranch job has a
  periodic folder trigger (1 minute, set by Job DSL in the JCasC values): the
  controller asks Gitea what changed and builds it. At work, GitHub pushes an
  event instead (a webhook to /github-webhook/ or /git/notifyCommit with a
  token), usually with a slow periodic scan kept as a safety net. Polling is
  simple and survives a missed webhook; webhooks are fast and cheap. Both end
  in the same place: branch indexing, then the branch property strategy
  decides whether a build is scheduled.

FIX
  Remove the property from Branch Sources -> Property strategy in the job
  configuration. Or, since the job is code, put it back as code defines it:
  Manage Jenkins -> Configuration as Code -> Reload existing configuration
  (Job DSL regenerates demo-api without the hand edit). Saving the config
  re-indexes at once, so the README commit that never built builds now.
  Prove it the way Sam does: push to a branch and DO NOT touch Jenkins; a
  build appears within a scan interval. That is what the check does.
  If feature branches really must not build on every push, the place for
  that is a deliberate rule in the Job DSL (e.g. "named branches get
  different properties": main builds, feature/* suppressed), reviewed and
  version-controlled, not a UI toggle that applies to everything.

NOT ACCEPTABLE
  - Telling Sam to keep clicking Build Now (the ticket is about the trigger).
  - Adding `triggers { pollSCM('* * * * *') }` to the Jenkinsfile or library
    to make builds happen anyway: a second trigger in every repo that copies
    it, polling Gitea per repo, and it leaves the actual cause in place.
    (PENALTY 20)

WHAT STOPS IT RECURRING
  - The job is defined in code; a hand edit in the UI is drift that nobody
    reviewed and that the next JCasC reload silently reverts (or not, if it
    never reloads). Changes to jobs go through the repo; admins who must
    change something live say so in the channel and put a date on it.
  - Alert on "commits detected but no build scheduled", or on a repo whose
    last build is older than its last commit: this was two hours of silence.
  - Know which mechanism you have: where a webhook is used, watch its
    delivery log (Gitea/GitHub "Recent deliveries") as well as Jenkins.

SAY THIS IN THE INTERVIEW
  "'Pushes don't build' and 'builds don't work' are different problems. Build
  Now worked, so I looked at the trigger. In a multibranch job the trigger is
  branch indexing, so I read the scan log: it saw the commit and said it did
  not schedule a build. That pointed at the branch property strategy: someone
  had suppressed automatic triggering from the UI. I removed it, verified by
  pushing a branch and not touching Jenkins, and pointed out the job is
  generated from code, so the edit was drift. For the long term I proposed
  alerting on commits that never produced a build, and, if capacity really is
  the problem, a deliberate rule in the Job DSL instead of a toggle."
