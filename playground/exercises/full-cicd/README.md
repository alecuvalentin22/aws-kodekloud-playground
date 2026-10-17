# Exercise: a full CI/CD pipeline, from commit to production (60 to 90 minutes)

Not a scored drill: nothing is broken for you and there is no clock. You **write**
one complete declarative pipeline, stage by stage, and run it for real on the
playground, end to end:

```text
git push
  -> checkout
  -> unit tests            (JUnit report in Jenkins)
  -> build image           (rootless BuildKit, no Docker daemon, no privileged pod)
  -> push to the registry  (tag = the git commit)
  -> deploy to staging     (kubectl apply, then WAIT: rollout status)
  -> smoke test staging    (curl the running service)
  -> approval              (input + timeout, outside any agent)
  -> deploy to prod        (same image, same manifest)
  -> if prod does not become healthy: kubectl rollout undo, automatically
```

When you are done you can say "I have built this", and the job description line
*"Build, maintain, and troubleshoot Jenkins pipelines ... deploy to Kubernetes"* has an
example behind it. The shared library's `deployToEks` step already does the
apply-wait-rollback for teams; here you write it out once, so you can explain what it
does and what it is protecting you from.

| Step | You add | Minutes |
|---|---|---|
| 0 | set up, read the starter | 8 |
| 1 | the shape: `agent none`, an agent per stage | 5 |
| 2 | unit tests + `junit` | 8 |
| 3 | build and push the image, tag = git sha | 12 |
| 4 | deploy to staging and wait | 10 |
| 5 | smoke test | 8 |
| 6 | the approval: `input` + `timeout`, no agent | 8 |
| 7 | deploy to prod, with an automatic rollback | 12 |
| 8 | **break a release on purpose** and watch it roll back | 12 |
| 9 | `./check.sh`, the Q&A, `./cleanup.sh` | 8 |

You need the playground running (`play doctor` all green) and a terminal where `play`
works: on the home lab, `ssh homelab-1-wsl`. Jenkins is http://localhost:30094 there
(login `admin`; the password is in `~/.local/state/platform-lab-playground/creds.env`).
Namespaces used: `cicd-staging` and `cicd-prod` (no drill touches them).

---

## 0. Set up, and read the starter

```bash
cd ~/platform-lab/playground/exercises/full-cicd
./seed.sh
```

It creates:

* namespaces **`cicd-staging`** and **`cicd-prod`**, the Jenkins agent's right to deploy into those two
  *and nothing else*, and a ConfigMap `release-config` in each: **`MODE=relaxed` in staging, `MODE=strict` in prod**
  (remember this: it is how a release can be healthy in one and sick in the other);
* the repo `payments/cicd-demo` in Gitea, and your clone in `~/platform-playground/cicd-demo`;
* the Jenkins job **`cicd-demo`** (Pipeline script from SCM, branch `main`, `Jenkinsfile`).

In your clone, read, in this order:

* `app.py`, `test_app.py`: a Flask service. `/` returns its version; `/healthz` is the health endpoint.
  Read `known_bad_in_strict_mode()`: you will use it in step 8.
* `Dockerfile`: bakes `VERSION` into the image (`--build-arg VERSION=<tag>`, which `buildImage` passes).
* `k8s/deployment.yaml`: one manifest for both environments, `IMAGE_PLACEHOLDER` for the image,
  `maxUnavailable: 0`, a readiness probe on `/healthz`.
* `Jenkinsfile`: the **starter**, with a TODO per step. Run the job once now (Build Now, in the UI): it should go green and do nothing.

The tools are the ones the golden path uses: `platform-lib`'s pod template (`libraryResource('podtemplates/build.yaml')`
gives you containers `python`, `buildkit` and `deploy`) and its `buildImage` step. Skim
`~/platform-playground/platform-lib/vars/buildImage.groovy` and `resources/podtemplates/build.yaml`.

Work in the clone: edit, `git commit`, `git push`, then **Build Now**.

> **Reference solution:** `solution/Jenkinsfile` in this directory is the finished pipeline.
> It is clearly marked, and it is for **comparing** after you have written yours, not for starting.

## 1. The shape: `agent none` and an agent per stage

The starter already has it. Understand it before you add to it:

```groovy
pipeline {
    agent none                              // no pod for the pipeline as a whole
    stages {
        stage('Build and stage') {
            agent { kubernetes { yaml libraryResource('podtemplates/build.yaml'); defaultContainer 'python' } }
            stages { ... }                  // test, build, staging, smoke: ONE pod, one workspace
        }
        stage('Approve prod') { ... }       // no agent: nothing is held while a human decides
        stage('Deploy prod')  { agent { kubernetes { ... } } ... }
    }
}
```

**Why:** an agent is a pod holding CPU and memory. A pipeline with `agent` at the top keeps its pod through the
*whole* run, including the hour someone takes to click Approve, and with limited agents that blocks other
teams' builds (drill 43 is exactly that). So the approval stage gets no agent, and prod gets a fresh one.
Sequential `stages { }` inside a stage share its agent, so test, build, deploy and smoke test pay for one pod start.

## 2. Unit tests, published

Replace the `Unit tests` echo with:

```groovy
stage('Unit tests') {
    steps { sh 'pip install -q -r requirements.txt && python -m pytest -q --junitxml=test-results.xml' }
    post { always { junit 'test-results.xml' } }
}
```

Run. Open the build: **Test Result** lists the tests, and the build has a trend.

**Why `always`:** when a test fails, the build stops at that stage, and `post { always }` still runs, so the report of
*which test failed* is published exactly when somebody needs it. `junit` in the normal `steps` would be skipped.

## 3. Build the image and push it, tagged with the commit

```groovy
stage('Build and push image') {
    steps {
        script {
            env.SHA   = env.GIT_COMMIT.substring(0, 8)          // set by the checkout Jenkins did for you
            env.IMAGE = "${env.PLATFORM_REGISTRY}/payments/cicd-demo:${env.SHA}"
            buildImage(repository: "${env.PLATFORM_REGISTRY}/payments/cicd-demo", tag: env.SHA, context: '.', push: true)
        }
    }
}
```

Run, then look in the registry (the stand-in for ECR):

```bash
curl -s http://localhost:5001/v2/payments/cicd-demo/tags/list
```

**Why the tag is the commit:** it answers "what is running?" with a thing you can `git show`. `latest` cannot
(it moves), a build number cannot (it is only meaningful inside Jenkins), and a rollback to "latest" rolls back to
nothing. `env.X = ...` inside `script { }` is how a value travels to later stages.

**Why rootless BuildKit:** no Docker daemon on EKS nodes (containerd), Docker-in-Docker needs a privileged
container (root on the node), kaniko is archived. See the comments in `podtemplates/build.yaml`.

## 4. Deploy to staging, and wait

```groovy
stage('Deploy staging') {
    steps {
        container('deploy') {                   // the container with kubectl
            sh '''
                set -eu
                rm -rf .rendered && mkdir .rendered
                sed "s|IMAGE_PLACEHOLDER|$IMAGE|g" k8s/deployment.yaml > .rendered/deployment.yaml
                kubectl -n cicd-staging apply -f .rendered/
                kubectl -n cicd-staging rollout status deployment/cicd-demo --timeout=120s
            '''
        }
        // step 7 adds a stash line here
    }
}
```

Run, then `kubectl --context kind-playground -n cicd-staging get pods`.

**Why the wait is the point:** `kubectl apply` returns the moment the API server *accepted* the object. It says nothing
about whether the pods start. A pipeline that stops there is green while the pods crash-loop (drill 02). `rollout status`
blocks until the new ReplicaSet is fully available or the timeout hits, which fails the stage: only then does the colour mean something.
Render the image into the manifest **once**, then apply; `apply` followed by `kubectl set image` starts two rollouts.

## 5. Smoke test the running service

The pipeline runs inside the cluster, so it can call the Service by its DNS name:

```groovy
stage('Smoke test staging') {
    steps {
        container('deploy') {
            sh '''
                set -eu
                base=http://cicd-demo.cicd-staging.svc.cluster.local
                curl -fsS "$base/healthz"
                served=$(curl -fsS "$base/" | sed -n 's/.*"version":"\\([^"]*\\)".*/\\1/p')
                echo "staging serves version: $served"
                [ "$served" = "$SHA" ] || { echo "staging serves $served, expected $SHA"; exit 1; }
            '''
        }
    }
}
```

**Why, when the readiness probe already passed:** readiness says "the process answers its probe". The smoke test
asks "is the thing I just built the thing that is serving?" (the version check catches a deploy that went green
without changing anything: drill 48) and "does the real URL work for a caller?". Keep it a few seconds long: it
is a gate, not a test suite.

## 6. The approval: `input`, a timeout, and no agent

Add this stage after the closing brace of `Build and stage` (at the top level of `stages`, not inside it):

```groovy
stage('Approve prod') {
    options { timeout(time: 10, unit: 'MINUTES') }
    steps {
        input id: 'promote', message: "Promote ${env.SHA} to prod?", ok: 'Promote'
    }
}
```

Run it. At the stage the build pauses: open the build page and click **Promote**. While it waits, look at the cluster:

```bash
kubectl --context kind-playground -n jenkins get pods        # no cicd-demo agent pod: only the controller
```

**Why outside an agent:** the stage has no `agent`, and the earlier pod is gone. Waiting costs nothing. Put `input`
inside the first stage's agent and that pod sits idle (and counts against your agent limit) until someone clicks.
**Why a timeout:** an approval nobody answers would otherwise stay open for ever, and `disableConcurrentBuilds`
would make every later release queue behind it. When the timeout fires the build is *aborted*, not failed (try it
once: set `time: 1`, let it expire, then put 10 back). Real pipelines also set `submitter: 'release-managers'`
so that not just anybody can promote.

## 7. Deploy to prod, with an automatic rollback

First, let the manifests travel from the first pod to the second. In `Deploy staging`, after the `container { }` block:

```groovy
        stash name: 'manifests', includes: 'k8s/*.yaml'
```

Then the prod stage, after `Approve prod`:

```groovy
stage('Deploy prod') {
    agent { kubernetes { yaml libraryResource('podtemplates/build.yaml'); defaultContainer 'deploy' } }
    options { skipDefaultCheckout() }                 // do not check main out again
    steps {
        unstash 'manifests'
        sh '''
            set -eu
            rm -rf .rendered && mkdir .rendered
            sed "s|IMAGE_PLACEHOLDER|$IMAGE|g" k8s/deployment.yaml > .rendered/deployment.yaml
            kubectl -n cicd-prod apply -f .rendered/
            kubectl -n cicd-prod rollout status deployment/cicd-demo --timeout=90s
        '''
    }
    post {
        failure {
            sh '''
                kubectl -n cicd-prod get pods -l app=cicd-demo -o wide || true
                kubectl -n cicd-prod rollout undo deployment/cicd-demo
                kubectl -n cicd-prod rollout status deployment/cicd-demo --timeout=90s
            '''
        }
    }
}
```

Run it, approve, and check both namespaces run the same commit:

```bash
for ns in cicd-staging cicd-prod; do kubectl --context kind-playground -n $ns get deploy cicd-demo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'; done
```

**Why `skipDefaultCheckout` + stash/unstash:** a new agent normally checks out *the branch tip again*. If someone merged
to `main` while the approval sat open, prod would get manifests nobody tested. Stashing the manifests in the first
stage and unstashing them in the last means *what you tested is what you ship*. (The image is already pinned by its tag.)
**Why `post { failure }` and not a step after `rollout status`:** a failing step ends the stage; `post` runs after it
fails, on the same pod, so the undo happens exactly when it is needed. It leaves the pod list in the log first,
because whoever reads that red build needs to see *why*. `rollout undo` can only go back to a revision that exists:
the very first prod deploy has nothing to undo (which is why step 8 comes after a good release).

## 8. Break a release on purpose

You have one good release in prod. Now ship a bad one that **looks fine in staging**. In your clone:

```bash
printf '\nENV KNOWN_BAD=true\n' >> Dockerfile
git commit -am "release: enable the new cache" && git push
```

Build now. Predict first: the unit tests pass (they run relaxed). Staging is `MODE=relaxed`, so it is healthy and the
smoke test passes. You approve. Prod is `MODE=strict`, `/healthz` returns 500, the new pod never becomes ready, and with
`maxUnavailable: 0` the old pod keeps serving while the rollout stalls. After 90 seconds `rollout status` fails, the
stage goes red, `post { failure }` runs `kubectl rollout undo`, and the console says `deployment.apps/cicd-demo rolled back`.

Check that the system did its job:

```bash
kubectl --context kind-playground -n cicd-prod get deploy cicd-demo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl --context kind-playground -n cicd-prod rollout history deployment/cicd-demo
curl -s http://localhost:5001/v2/payments/cicd-demo/tags/list
```

Prod still runs the *previous* commit, the build is red, and staging runs the bad one (which is correct: staging is
where you find out). **A red build here is the pipeline protecting production.** Say that to the developer who
asks "why is Jenkins red": the failing stage, the pod state it printed, and "prod never served it".

**Run `./check.sh` (step 9) now, while the red build is the latest one.** It looks for a failed release *after* your
last green build, so shipping a fix first would hide it. Only then go forward: `git revert HEAD && git push`, build, approve,
and both namespaces run the fixed commit.

## 9. Check, then say it out loud

```bash
./check.sh
```

It reads the Jenkinsfile on `main`, the last green build, the last failed one, and the cluster: that the pipeline
has `agent none`, `junit`, `buildImage`, a wait, `input` inside a `timeout` and **outside any agent**, and a rollback
in `post { failure }`; that the last green build ran **the same commit in `cicd-staging` and `cicd-prod`** and the image
tag is that commit; and that a later red build reached prod, was rolled back by the pipeline, and left prod on the good commit.
Exit 0 = done. Then `./cleanup.sh` (job, repo, clone and both namespaces).

---

## Why each stage exists (the answer to "walk me through your pipeline")

| Stage | The failure it exists to stop |
|---|---|
| unit tests, `junit` | a broken change gets any further; and the reader can see which test |
| build image | the Dockerfile itself is broken; tests ran against source, not against what ships |
| push, tag = commit | "what is running?" has no answer; rollback has no target |
| deploy staging + `rollout status` | a manifest or config that does not start; green-but-crashing |
| smoke test | the deploy is "healthy" but not the build you think, or not reachable |
| approval (`input`, timeout, no agent) | a human decision where policy requires one, without holding a pod or blocking forever |
| deploy prod, same image and manifest | testing one thing and shipping another |
| `post { failure }` rollback | prod stays on the last good version when the rollout fails |

## Interview Q&A

**Walk me through a pipeline you built.**
Say the diagram at the top, then the three decisions: tag = commit, wait for the rollout before calling it green,
and approval outside any agent with a timeout. Then step 8: the bad release that passed staging, was stopped by
`rollout status` in prod, and was undone by `post { failure }`.

**Why can a release pass staging and fail in prod?**
Different configuration, data, quotas or dependencies (here `MODE`). Staging proves the build starts; it does not prove
prod's environment. Hence the rollout wait and rollback in prod too, and keeping the config differences small and visible.

**Why not `latest`?**
It moves. You cannot tell what runs, cannot roll back to "the previous latest", and two nodes may hold different images
under the same name. A commit tag (or a digest) is immutable and traceable.

**What does `kubectl rollout undo` actually do, and when does it not work?**
It re-applies the previous ReplicaSet's pod template (a new revision). It needs a previous revision (`revisionHistoryLimit`),
and it undoes only the Deployment, not a database migration or a ConfigMap change that came with the release.

**Where does `input` belong and what can go wrong?**
Outside any agent, in a `timeout`, with a `submitter`. Inside an agent it holds a pod; without a timeout it can block the
pipeline (and, with `disableConcurrentBuilds`, every later one) indefinitely; without a submitter anyone with access promotes.

**Why `stash`/`unstash` instead of a second checkout?**
The second checkout takes the branch tip *now*, which may include commits nobody tested. Stash carries exactly the files
that were tested. (For large or long-lived files use an artifact repository, not stash.)

**Why is the pipeline red when the rollback worked?**
Because the release did not happen. Green means "this commit is live and healthy". The rollback is the pipeline working;
the red is the signal to the developer, with the pod state in the log.

**What would you add for production?**
Immutable digests instead of tags in the manifest, a canary or blue-green step with metrics before the full rollout, a
smoke test in prod too, notifications from `post`, per-environment credentials and namespaces scoped by RBAC (the agent here
can deploy to exactly these two namespaces), and the pipeline code in a shared library once three teams have copied it.
