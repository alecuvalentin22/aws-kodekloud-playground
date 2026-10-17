# Exercise: every kind of Jenkins job, built by hand (60 to 90 minutes)

Not a scored drill: nothing breaks and there is no clock. You **build** one job
of each kind in the playground's Jenkins, for the same tiny app, make each one
green, and learn what separates them. Afterwards you can answer the questions
this job description line produces: *"Build, maintain, and troubleshoot Jenkins
pipelines used across engineering teams"*, and mean it.

| Step | Job you build | What it teaches | Min |
|---|---|---|---|
| 0 | (set up) | the app, the agent label, where things are | 5 |
| 1 | (a) `jt-freestyle` | the form-based job, and why teams moved off it | 8 |
| 2 | (b) `jt-scripted`, (c) `jt-declarative` | the two pipeline syntaxes, CPS, when scripted is still needed | 20 |
| 3 | (d) `jt-multibranch` | branch discovery, scanning, orphaned branches | 12 |
| 4 | (e) `jt-params` | parameters, and the first-run trap | 10 |
| 5 | (f) `jt-downstream` + `jt-upstream` | one job starting another, passing a parameter | 10 |
| 6 | (g) `jt-matrix` | declarative `matrix` | 5 |
| 7 | (h) `jt-seed` | jobs as code: Job DSL, and script approval | 10 |
| 8 | triggers | `pollSCM` / cron on a pipeline | 5 |
| 9 | `./check.sh`, the Q&A below, `./cleanup.sh` | | 10 |

You need the playground running (`play doctor` all green) and a terminal where
`play` works: on the home lab, `ssh homelab-1-wsl`. The Jenkins UI is
http://localhost:30094 on that box (http://192.168.0.23:30094 from your Mac), login `admin`,
password in `~/.local/state/platform-lab-playground/creds.env`.

---

## 0. Set up

```bash
cd ~/platform-lab/playground/exercises/jenkins-job-types
./seed.sh
```

This creates a tiny repo, `payments/jobtypes-demo`, in the playground's Gitea
(http://localhost:30300) and a clone of it in `~/platform-playground/jobtypes-demo`:

| File | What it is |
|---|---|
| `greet.sh`, `test.sh` | the "app" and its test: `sh ./test.sh` prints `1 test passed` |
| `Jenkinsfile` | what the multibranch job runs (step 3) |
| `examples/*.groovy` | the pipeline scripts of steps 2 to 6: **paste these, but read them first** |
| `jobs/dsl.groovy` | the Job DSL of step 7 |

Two facts every job below depends on, both from the playground's Jenkins:

* The **controller has 0 executors**. Nothing builds on it. Every build needs an
  agent, and agents here are pods the Kubernetes plugin creates on demand.
* The plugin's default pod is selected by the label **`jenkins-jenkins-agent`**.
  It is a plain `jnlp` container with `sh` and `git`, which is all this app needs.
  (The golden-path pipelines of the other drills define their own pod in the
  shared library instead.)

The git URL inside the cluster, which every job uses:
`http://gitea.git.svc.cluster.local:3000/payments/jobtypes-demo.git`.

> **Stuck on a step?** `solution/create-jobs.sh <kind>` creates that job through
> the REST API, like the UI would. Compare what it produces with your own job's
> `config.xml` (`/job/NAME/config.xml`): a job is just that file.

---

## 1. (a) Freestyle: a form, no code

New Item, name `jt-freestyle`, type **Freestyle project**.

* *General*: tick **Restrict where this project can be run**, label `jenkins-jenkins-agent`.
* *Source Code Management*: Git, the URL above, branch `*/main`.
* *Build Steps*: **Execute shell**, `sh ./test.sh`.
* Save, **Build Now**, open the console. Watch the agent pod start (`kubectl --context kind-playground -n jenkins get pods -w`).

Then see what you made: open `/job/jt-freestyle/config.xml`. Everything you
clicked is in that file, and it lives **only inside Jenkins**.

**Break it on purpose (2 min):** change the label to `windows-builder` (one nothing claims) and build.
It sits in the queue as *Waiting for next available executor*, forever: the controller has no executors, and
the Kubernetes plugin only starts a pod for a label one of its pod templates claims. No error anywhere. This is
the shape of drill 05, and the first thing to check when "my build never starts". Put the label back.

**Why teams moved off freestyle** (say this out loud):
* the definition is a form in a database, not a file: no review, no history, no
  `git blame`, no "what changed before it broke";
* it cannot be copied between 50 teams except by hand, so it drifts;
* no stages, no parallelism, no `post`, no restart from a stage, no library to share;
* the controller's disk is the only backup (see step 7 for the fix).

It is still fine for a one-off admin task or a cron job nobody will touch. Say that too.

## 2. (b) Scripted and (c) declarative: the same pipeline twice

Two Pipeline jobs, same behaviour, different syntax. New Item, type **Pipeline**:

* `jt-scripted`: *Pipeline script*, paste `examples/scripted.groovy`.
* `jt-declarative`: *Pipeline script*, paste `examples/declarative.groovy`.

Run both. Open the **Pipeline Overview** (stage view) of each.

Read the two files side by side:

| | scripted (`node { }`) | declarative (`pipeline { }`) |
|---|---|---|
| shape | any Groovy program | a fixed structure: `agent`, `stages`, `steps`, `post`, `options`, `when`... |
| checked before running | no: a typo fails mid-build | yes: the linter rejects a bad structure up front |
| error handling | `try/catch/finally` yourself | `post { always / success / failure }` |
| conditions | `if` | `when { branch 'main' }` (the stage is skipped, and shown as skipped) |
| restart from a failed stage | no | yes (declarative only) |
| logic that does not fit | already there | inside `script { }` (see the `Report` stage) |

**Experiment 1: the linter.** Declarative can be validated without running it:

```bash
. ~/.local/state/platform-lab-playground/creds.env
curl -s -u admin:$JENKINS_PASSWORD -F "jenkinsfile=<examples/declarative.groovy" http://localhost:30094/pipeline-model-converter/validate
sed 's/^    stages {/    stagez {/' examples/declarative.groovy > /tmp/bad.groovy
curl -s -u admin:$JENKINS_PASSWORD -F "jenkinsfile=</tmp/bad.groovy" http://localhost:30094/pipeline-model-converter/validate
```
The second call names the line. A scripted pipeline has no such pre-check.

**Experiment 2: where scripted is still needed.** Stages *computed at runtime*.
In `jt-scripted`, add after the `Test` stage:

```groovy
    def targets = ['alpha', 'beta', 'gamma']       // imagine: read from a file or an API
    def branches = [:]
    for (t in targets) {
        def name = t                                // capture the loop variable per iteration
        branches[name] = { stage("build ${name}") { sh "echo building ${name}" } }
    }
    parallel branches
```
A declarative `stages { }` list is static; the number of stages cannot depend on data.
`matrix` (step 6) covers a fixed grid, and `script { parallel(map) }` works inside a
declarative step, but *generating stages from data* is scripted territory.
Shared-library code (`vars/*.groovy`) is scripted Groovy too.

**Experiment 3: CPS, the thing behind every strange Pipeline error.** A pipeline is
not run by Groovy directly: Jenkins transforms it (Continuation Passing Style) so it
can pause, survive a controller restart and resume. The price: whatever your script
holds in a variable *across a step* must be serializable. In `jt-scripted`, replace the
body with:

```groovy
node('jenkins-jenkins-agent') {
    def m = ('release-1.2' =~ /release-(\d+)\.(\d+)/)   // a java.util.regex.Matcher: NOT serializable
    sh 'sleep 1'                                         // a step: the pipeline may be saved here
    echo "major ${m[0][1]}"
}
```
Run it: `java.io.NotSerializableException: java.util.regex.Matcher`. Fixes: use the
Matcher inside one `@NonCPS` method that returns a plain String, or do the parsing in
`sh` on the agent. Put the original script back (`examples/scripted.groovy`) and run it green again.

Both jobs must end green for `check.sh`.

**Say it out loud:** "Declarative for almost everything, because it is checkable,
readable and restartable. Scripted when stage structure depends on data, and inside
shared libraries. Whichever I use, the Jenkinsfile lives in git."

## 3. (d) Multibranch: one job, a job per branch

New Item, name `jt-multibranch`, type **Multibranch Pipeline**.

* *Branch Sources*: Add source, **Git**, the URL above (no credentials: the repo is public).
* *Build Configuration*: by Jenkinsfile, Script Path `Jenkinsfile`.
* *Scan Multibranch Pipeline Triggers*: **Periodically if not otherwise run**, 1 minute.
* *Orphaned Item Strategy*: Discard old items (days to keep empty, max 5).
* Save. It scans immediately: open **Scan Multibranch Pipeline Log**. Find the lines
  `Checking branch main`, `Jenkinsfile found`, `Met criteria`. A `main` job appears and builds.

Now create a branch the way a developer would:

```bash
cd ~/platform-playground/jobtypes-demo
git switch -c feature/hello
echo "# hello" >> README.md && git commit -am "feature: hello" && git push -u origin feature/hello
```
Wait for the scan (or **Scan Multibranch Pipeline Now**). A job `feature%2Fhello`
appears and builds the *branch's* Jenkinsfile, with `env.BRANCH_NAME=feature/hello`.
Open its console: the `Greet` stage prints the branch name.

Questions the scan log answers, and you should now be able to read it for:
* **Why is there no job for my branch?** Either Jenkins did not look at it (a name filter
  in the branch source's *Behaviours*: the log says `Processed 2 branches` but only
  checks one) or it looked and the file at the Script Path is missing (`Jenkinsfile not found`,
  `Does not meet criteria`). Drill 46 is exactly this.
* **Why did a push not start a build?** Branch property *suppress automatic SCM
  triggering*, or nothing told Jenkins (webhook) and the periodic scan has not run yet. Drill 45.

**What happens when the branch is deleted?** Do it and rescan:

```bash
git switch main && git push origin --delete feature/hello
```
The scan log ends with `Evaluating orphaned items ... Will not remove feature/hello as
it is only #1 in the list`, and the branch job turns grey: it is *orphaned*, kept by the
**orphaned item strategy** (here: keep the 5 most recent), pruned after that. That
strategy is the cure for the "140 stale branch jobs" problem. Leave one branch job for
`check.sh`: recreate the branch (`git switch -c feature/hello2`, push) and let it build green.

**Not available here, say it in words:**
* **Pull request builds**: need a branch-source plugin that talks to the host's API
  (GitHub Branch Source, the Gitea plugin; neither is installed). With it, *Behaviours*
  gains "Discover pull requests from origin"; PR jobs are named `PR-17`, and `CHANGE_ID`,
  `CHANGE_TARGET` are set. Build the *merge* result, not just the PR head, or you test
  code that will never exist. Treat PRs from forks as untrusted (they can edit the Jenkinsfile).
* **Organization folder**: one level above multibranch. Point it at a GitHub org (or
  Gitea org): it finds every repository with a Jenkinsfile, makes a multibranch project
  for each, and keeps doing so as repos are created and deleted. Same plugins, so
  not installed here.

## 4. (e) A parameterized pipeline, and the first-run trap

New Pipeline job `jt-params`, paste `examples/params.groovy`. Read it: a `choice`
(first entry = the default) and a `booleanParam`, declared **in the Jenkinsfile**.

1. Open the job page. There is **Build Now**, not "Build with Parameters": Jenkins
   does not know the parameters yet. **They exist only after a run executes the `parameters { }` block.**
2. Click **Build Now**. It ends `NOT_BUILT` with "Parameters registered. Nothing done."
   (that is the script's own first-run guard).
3. Reload the job page: now there is **Build with Parameters**. Run it with `TARGET=prod`, `LOUD` ticked.
   The console says `HELLO FROM PROD`.

That is the trap behind drill 47. What actually happened on step 2, and why the guard is
`env.TARGET == null` and not `params.TARGET == null`: a declared parameter the run was
not given **does not come out null**. `params.TARGET` quietly holds its default (`staging`,
the first choice) and `LOUD` is `false`; only the *environment variable* `TARGET` is missing.
So a pipeline that "just reads params" runs happily with defaults on the first run, after a
rename, and after anyone adds a parameter. For anything that deploys, make the pipeline refuse
instead (`error('TARGET is required')`).

Remember: `params.X` is the declared parameter (a `Boolean` for booleans); `env.X` is the same
value as an environment variable for `sh` steps (always a String, `'true'`).

**Say it out loud:** "A Jenkinsfile's parameter list only takes effect when a build runs it,
so changing parameters is a two-step change, and the pipeline must fail on missing input rather than default."

## 5. (f) Upstream and downstream, passing a parameter

The downstream job first, **and run it once by hand**:

* `jt-downstream`: Pipeline, paste `examples/downstream.groovy` (a `WHO` string parameter, fails if empty).
  Build Now. It fails with "WHO is required": expected, and it has now registered `WHO`.

Then the upstream:

* `jt-upstream`: Pipeline, paste `examples/upstream.groovy`. Its `build job: 'jt-downstream', parameters: [...]`
  starts the downstream with `WHO=jt-upstream #N`. Run it.

Open `jt-downstream`'s newest build: *Started by upstream project "jt-upstream" build number N*, and its
**Parameters** page shows `WHO`. The upstream's console shows `Starting building: jt-downstream #2` and
`completed: SUCCESS`.

Things to try, 3 minutes:
* In `jt-upstream` rename the parameter to `WHOM` and run. The downstream **drops it**
  (it is not defined there), runs with its default and fails; the only trace is a WARNING in the
  controller's log, not in either console. That is drill 48. Put it back.
* `wait: false` makes the upstream go green without waiting; if the downstream then fails, nobody is told.
  `propagate: false` makes it wait but ignore the result. Know the defaults (`wait: true`, `propagate: true`).
* Reverse direction: a declarative trigger `triggers { upstream(upstreamProjects: 'jt-upstream', threshold: hudson.model.Result.SUCCESS) }`
  starts a job *when another finishes*, with no parameters. Use `build` when you need to pass data or wait.
* The freestyle equivalent ("Trigger parameterized build on other projects") needs the Parameterized
  Trigger plugin, which is **not installed** here. Pipelines do not need it.

## 6. (g) A declarative matrix

New Pipeline `jt-matrix`, paste `examples/matrix.groovy`. One `stage` definition is run once for
every combination of the `axes` (3 greetees x 2 places = 6), minus the `excludes` (1) = 5 cells, each on
its own agent pod, in parallel. In the console find `Branch: Matrix - GREETEE = 'Ada', WHERE = 'dev'`.

Where it is used: the same tests on several Python versions or operating systems. What it costs: cells
multiply fast (3 x 4 x 5 = 60 pods). The freestyle cousin, "Multi-configuration project", needs the Matrix
Project plugin; use the declarative one.

## 7. (h) Jobs as code: Job DSL

Everything so far was clicked together, which is how a Jenkins becomes a pet nobody dares restart.
The fix is to make *the jobs* code too. The playground's own `demo-api` job is created this way: see
`multibranchPipelineJob('demo-api') { ... }` in `setup/jenkins-values-local.yaml`, applied by JCasC at start-up.

Read `jobs/dsl.groovy` in your clone. Then build the **seed job**:

* New Item `jt-seed`, **Freestyle project**, label `jenkins-jenkins-agent`, Git source as in step 1.
* Build Step: **Process Job DSLs**, *Look on Filesystem*, DSL Scripts `jobs/dsl.groovy`. Removed jobs: **Delete**.
* Save and **Build Now**.

It fails: `ERROR: script not yet approved for use`. A DSL script runs with the controller's
full power, so Jenkins makes an administrator read and approve **the exact script** (a hash of it).
Open **Manage Jenkins > In-process Script Approval**, read what is pending, approve it, build again.
(The same gate as drill 04. The alternative is the Groovy sandbox plus the Authorize Project plugin,
which is not installed here.) The log ends with `Added items: jt-dsl-freestyle, jt-dsl-pipeline`.

Run both generated jobs once. Then:
* Edit one of them in the UI (change the description), run `jt-seed` again: **your edit is gone**. That
  is the point, and the reason nobody edits generated jobs by hand.
* Delete the `job('jt-dsl-freestyle')` block from `jobs/dsl.groovy`, commit and push, run the seed:
  the job is deleted (`Removed jobs: Delete`). Put it back and run the seed again.

Job DSL and JCasC are different layers: **JCasC** configures Jenkins itself (clouds, credentials,
global libraries, security); **Job DSL** creates jobs. Together they make the controller disposable.

## 8. Triggers on a pipeline

Add one block to `jt-declarative` (inside `pipeline { }`, next to `options`):

```groovy
    triggers { pollSCM('* * * * *') }     // ask git every minute whether anything changed
```
Save. **Nothing happens yet**: a trigger declared in a Jenkinsfile is registered when the job runs, same as
parameters. Build Now once. Then push a commit to `main` from your clone and wait a minute or two: a build appears
with *Started by an SCM change*.

Polling is the fallback. The normal way is a **webhook** (the git host calls Jenkins on push), which
is instant and puts no load on git; the playground has no inbound webhook, which is why `demo-api` polls.
`cron('H 2 * * *')` is for time-based work (`H` spreads the load: never use `0 2 * * *` on 200 jobs).

## 9. Check, then say it out loud

```bash
./check.sh
```

It checks, through the Jenkins API, that each job exists **with the right type** (Jenkins's `_class`:
`FreeStyleProject`, `WorkflowJob`, `WorkflowMultiBranchProject`), is the kind of pipeline you were asked for
(scripted vs declarative is read from the script), and has a green last build, and that the parameter,
upstream, matrix, Job DSL and trigger parts really happened. Exit 0 = all done.

Then clean up: `./cleanup.sh` (deletes only the `jt-*` jobs, the exercise repo and your clone).

---

## Interview Q&A (say each out loud first, then compare)

**1. Freestyle or Pipeline?**
Pipeline, with the Jenkinsfile in git, for anything a team depends on: it is reviewed, versioned, can be
shared through a library, and has stages, parallelism, `post` and restart. Freestyle is configuration stored
inside Jenkins that cannot be diffed or reproduced; fine for a throwaway admin job.

**2. Declarative or scripted, and when do you still need scripted?**
Declarative by default: fixed structure, validated before it runs, `post`, `when`, restart from a stage. Scripted
when the stage structure depends on data computed at runtime, or for the logic inside shared libraries. Declarative
lets you drop into scripted for a bit with `script { }`.

**3. What is CPS, and what does `NotSerializableException` mean?**
Pipeline code is transformed so it can pause and survive a restart; every local variable alive across a step must
be serializable. A `Matcher`, a `JsonSlurper` result or an open stream held across `sh` breaks it. Do the work in a
`@NonCPS` method that returns plain data, or push it to a script on the agent. Also: heavy computation in Groovy runs
on the controller, so keep pipeline code thin.

**4. How does a multibranch job work?**
It asks the git source for its branches (indexing / scanning), and for each branch that has a file at the Script Path
("meets criteria") it creates a child job. Triggered by a webhook or a periodic scan. A branch with no job means it
was filtered out (Behaviours) or has no Jenkinsfile; the scan log says which.

**5. What happens to a branch's job when the branch is deleted?**
It becomes orphaned at the next scan and the *orphaned item strategy* decides: keep N or for N days, then delete.
Without a strategy you accumulate stale jobs on the controller.

**6. Multibranch versus organization folder?**
Multibranch = one repository, a job per branch and PR. Organization folder = a whole GitHub/Gitea org: it finds the
repositories with a Jenkinsfile and creates a multibranch project for each, automatically. New repo, CI with no clicks.

**7. How do pull request builds work?**
A branch source with PR discovery creates `PR-n` jobs with `CHANGE_ID`, `CHANGE_TARGET`; usually build the merge
with the target branch; mark the result back on the PR. Forks are untrusted: they can change the Jenkinsfile, so
use the trusted copy from the target branch and no credentials.

**8. A developer says "my parameters don't show up". Why?**
A Jenkinsfile's `parameters { }` only registers when a build runs it, so the form lags the code by one run, and that
first run gets defaults. After adding or renaming parameters, run once. In the pipeline, check for the missing
input and fail instead of defaulting, especially in a deploy job.

**9. `params` versus `env`?**
`params.NAME` is the declared parameter with its type (Boolean for a checkbox) and its default if the run was not
given a value. `env.NAME` is the same value as a String environment variable, which is what `sh` sees; it does not
exist for a run that was not given the parameter.

**10. How do you start one job from another, and pass data?**
The `build job: 'x', parameters: [...]` step, with `wait` and `propagate` set on purpose. The parameter must be
defined in the downstream job and must have run once, or Jenkins drops it (logged only in the controller log), and
the downstream runs with its defaults. Pass an exact tag or digest, never "latest". For reacting to another job's
completion without data, use the `upstream` trigger.

**11. `stash`/`unstash` versus `archiveArtifacts`?**
`stash` moves files between stages or agents *within one run* (short-lived, kept on the controller, keep it small),
for example the built output from a build agent to a test agent. `archiveArtifacts` keeps files *after* the run
for people and other jobs to download. Large or long-lived binaries belong in an artifact repository, not either.

**12. How do you add a manual approval to a pipeline?**
`input` inside `timeout`, and **outside any agent** (`agent none` at the top, an agent per stage), so the pipeline
does not hold an executor and a pod for hours while someone is at lunch. Limit who can approve with `submitter`.
Drill 43 is what happens otherwise.

**13. How do you use a secret in a pipeline?**
Store it as a credential in Jenkins (scoped to a folder, not global, where you can) and bind it with
`withCredentials([...])`, which injects it for the block and masks it in the log. Never `echo` it, never
write it into an image layer, and remember masking only covers the exact string (drills 12 and 44).

**14. Job DSL versus JCasC?**
JCasC (Configuration as Code) describes Jenkins's own configuration in YAML: clouds, credentials, security, global
libraries, and the seed jobs. Job DSL is a Groovy DSL that creates jobs (including multibranch). Together they make
the controller reproducible; the DSL script itself needs admin approval or a sandbox, as it runs with controller rights.

**15. How do you share pipeline code across teams, safely?**
A shared library: `vars/*.groovy` steps teams call, `src/` for classes, `resources/` for files. Teams pin a tag
(`@Library('lib@v1.2.0')`), the platform team releases like any dependency and tries changes on a branch or a pilot
team first. An unpinned library makes every commit to `main` an outage for every team (drills 07 and 09).
