ROOT CAUSE
  Two bugs, one hiding behind the other.

  1. The form was stale. A Jenkinsfile with a parameters {} block does not
     define the job's parameters until a build RUNS it: the block updates the
     job when the build starts. Priya merged the rename (ENV/TAG ->
     TARGET_ENV/IMAGE_TAG) and nobody ran the job afterwards, so "Build with
     Parameters" still offered the OLD fields. Sam filled ENV=prod, TAG=1.4.2;
     Jenkins recorded exactly that on the build's Parameters page. The new
     Jenkinsfile reads params.TARGET_ENV and params.IMAGE_TAG, which that run
     was never given. Jenkins does not complain: a declared parameter that
     the run did not supply gets its DEFAULT (the first choice, "staging"; an
     empty string). Measured on this Jenkins: params.NEWC is "first" and
     params.NEWS is "" (not null), while env.NEWC is null (the environment
     variable only exists for a supplied value). (Same trap on a brand-new
     job: the very first run of a parameterized Jenkinsfile has no parameters
     at all, so it runs with the defaults; that is why "Build Now" is shown
     instead of "Build with Parameters".)
  2. The pipeline turned "nothing was given" into a decision:
         String target = params.TARGET_ENV ?: 'staging'
         String tag    = params.IMAGE_TAG  ?: 'latest'
     Verbatim from Sam's run:
         Releasing demo-api:latest to staging
         RELEASE env=staging tag=latest dry_run=false
     Green, five seconds, wrong. An input that never arrived is a bug in the
     wiring, and a release job must say so instead of picking a default.

FIX
  1. Make Jenkins learn the new definitions: run the job once. After that the
     form shows TARGET_ENV, IMAGE_TAG, DRY_RUN. (Reproducing Sam's click
     already does this, which is how most people discover it.)
  2. Make missing input fatal, in the Jenkinsfile on main:
         String target = params.TARGET_ENV ?: error('TARGET_ENV is required')
         String tag    = params.IMAGE_TAG?.trim() ?: error('IMAGE_TAG is required')
     Push, run once more so job and file agree.
     (A choice() always has a value: its first entry. So "forgot to choose"
     and "chose staging" look the same. For a job that can hit prod, make the
     first entry a placeholder such as '-- choose --' and reject it.)

  The idiom for "the first run only registers the parameters" (a run that was
  started before the parameters existed has no environment variable for them):
         if (env.TARGET_ENV == null) {
             currentBuild.result = 'NOT_BUILT'
             echo 'Parameters registered. Build again with parameters.'
             return
         }
  Parameter changes in a shared release job are therefore a two-step change:
  merge, then run once (a DRY_RUN), then announce.

WHAT WORKS BUT HURTS (the check refuses these)
  - Hard-coding the answer (`target = 'prod'`): Sam's next release works, the
    one after for staging ships to prod. The check releases to BOTH.
  - Reverting the rename: the bot and the runbook already send the new names.
  - A default of `latest` anywhere on a release path: `latest` is whatever was
    pushed last, not a version. A release names what it ships.

PARAMETERS CHEAT SHEET
  - params.X is the declared parameter; env.X is the same value as an
    environment variable (for sh). Both are strings except booleans (params.X
    is a Boolean, env.X is the String 'true'). params.X on an undefined name
    is null, not an error; on a declared one the run was not given, it is the
    DEFAULT, and env.X is null.
  - choice(): the FIRST choice is the default. A prod-first list is a trap.
  - buildWithParameters on a parameter the job does not define is ignored
    (security default), see drill 48.

SAY THIS IN THE INTERVIEW
  "A declarative Jenkinsfile's parameters block only takes effect when a build
  runs it, so after a rename the form lags the code by one run. Sam's inputs
  were recorded under the old names and the pipeline read the new ones, got
  their defaults, and its '?: latest' turned the empty tag into a quiet wrong
  release. I ran the job once so the form matched, then made the pipeline
  fail on missing TARGET_ENV or IMAGE_TAG, because for a release job
  'nothing given' is an error, never a default. And I asked that parameter
  renames ship as merge, dry-run, announce."

  Related: drill 48 (the same lesson across two jobs), exercise
  `exercises/jenkins-job-types` (parameterized builds, step 5).
