ROOT CAUSE
  invoice-gen runs on a STATIC agent, and a static agent keeps its workspace
  between builds. Jenkins' git checkout updates tracked files only; vendor/,
  dist/ and build/ are git-ignored, so they stay. Two scripts trusted what was
  already there:
    ci/fetch-deps.sh   "vendor/money-lib exists -> cache hit". The cache has no
                       key: build #1 left money-lib 1.4.0, deps.lock now says
                       2.0.0, build #2 tests against the OLD library.
                         vendor/money-lib present, skipping fetch (cache hit)
                         FAIL test_half_cent_rounding: money-lib 1.4.0 is older
                         than deps.lock wants (2.0.0)
    ci/package.sh      `cp -R templates dist/` adds, never removes. Priya deleted
                       templates/legacy.tmpl, but dist/templates/legacy.tmpl is
                       still there from build #1, so once the tests pass the
                       release still SHIPS the template that leaks the internal
                       hostname. Security's question is a false green waiting to
                       happen: the build is green and wrong.
  A pod agent starts empty every build, so the same pipeline passes on pods
  (Sam: "ours just work"). Dynamic agents hide this class of bug; they do not
  remove it, it moves into whatever you cache on purpose.

FIX
  Start every build from a known state. The robust place is the START of the
  build, before the checkout:
    options { skipDefaultCheckout() }
    stage('Fresh checkout') { steps { cleanWs(); checkout scm } }
    post { cleanup { cleanWs() } }          // and tidy at the end too
  (or deleteDir(); or the git plugin's "Clean before checkout" extension, which
  runs `git clean -fdx`, ignored files included; plain `git clean -fd` would
  leave vendor/ and dist/ because they are ignored.)
  Why the START and not only the end: a post{} cleanup does not run if the
  build was aborted, the agent restarted or the node died mid-build. The next
  build then inherits the mess. Cleanup at the end is for tidiness and for
  not leaving credentials around.
  If a cache is wanted (vendor/ is slow to fetch), KEY it: restore it only when
  hash(deps.lock) matches, or check the version in the script.

NOT the fix
  - Job -> Workspaces -> Wipe Out: #3 goes green once, the next leftover bites.
  - Moving the job to a pod: it hides the bug, and the renderer licence is
    tied to build-01.
  - Fixing only vendor/: the stale dist/ still ships legacy.tmpl.

WHAT STOPS IT RECURRING
  - The pipeline owns its starting state (above), and `release.tgz` is checked
    for what it must NOT contain (a one-line grep, or a manifest diff).
  - Library-level default: put the clean-workspace behaviour in the shared
    pipeline template so a team cannot forget it.
  - For genuinely expensive caches: a keyed cache, not "directory exists".

SAY THIS IN THE INTERVIEW
  "First build green, second red with a library version that disagreed with
  the lock file. The checkout was right, so I asked what differs between a first
  and a second build on this machine: the workspace. It's a static agent, so
  vendor/ survived, and the script treated 'directory exists' as a cache hit. I
  also noticed the same leftover problem in the other direction: the removed
  template was still in dist/ and would have shipped once the tests passed. I did
  not wipe the workspace by hand; I made the pipeline start from an empty
  workspace, wiping before the checkout rather than only after, because a
  build that is aborted never runs its post section. Pod agents don't show this
  because every build starts empty; that is the real trade-off between
  static and dynamic agents: speed and caches versus a clean start."
