# CI track: Jenkins → ECR → EKS, with a portal and an artifact store

A practice environment for a mid-level DevOps role built around Jenkins
pipelines, reusable pipeline code, AWS, EKS and Docker. Everything here was
built and run on a live playground; the failures in
[drill 18](../drills/18-jenkins-pipeline-failures.md) are real output.

## What runs where

```mermaid
flowchart LR
  GH["GitHub<br/>main + branches"] -->|"multibranch scan<br/>every 5 min"| J["Jenkins controller<br/>EKS · ns jenkins"]
  J -->|"one pod per build"| A["agent pod<br/>python · buildkit · deploy"]
  LIB["shared library<br/>ci/shared-library"] -.->|"@Library('platform-lib')"| J
  A -->|"rootless BuildKit<br/>push (main only)"| ECR["ECR<br/>platform-lab/demo-api"]
  A -->|"kubectl apply<br/>rollout status"| APP["demo-api<br/>EKS · ns demo-ci"]
  ECR -->|"node pulls"| APP
  BS["Backstage<br/>EKS · ns backstage"] -.->|"reads catalog-info.yaml"| GH
  RT["Artifactory OSS<br/>did not fit the playground"]
```

| Piece | Where | Why there |
|---|---|---|
| Jenkins | EKS, `jenkins` ns | agents are pods: a build gets a clean container set and disappears |
| demo-api | EKS, `demo-ci` ns | the deploy target; agent RBAC is limited to this namespace |
| Backstage | EKS, `backstage` ns | catalog of what exists and who owns it |
| Artifactory OSS | **not running on the playground** | it needs ~2 vCPU and more than 3Gi. On the playground, Fargate is capped at 1 vCPU (a 2 vCPU service was deleted by the compliance job) and EKS nodes are t3.medium (OOMKilled). **Decision:** run it on a GCP e2-standard-2 VM (`terraform/gcp-artifactory`, written and validated, **not yet applied**). Jenkins reaches it over the internet like any SaaS registry. `terraform/ecs` and `ci/artifactory/` remain the AWS versions for a normal account. Drill 18 §8 is the story |
| Datadog | not installed | SaaS: needs a trial API key. `DD_API_KEY=... make datadog` |

URLs change every rebuild. Get them with `make urls` (EKS NodePorts: Jenkins
30094, demo-api 30095, Backstage 30096, Artifactory 30097).

## Build it

```bash
NODE_DESIRED=5 ./scripts/eks-up.sh               # ~20 min
make jenkins                                     # prints URL + admin password
make backstage
```

Then open Jenkins → `demo-api` → **Scan Multibranch Pipeline Now**.

## Read the code in this order

1. [`ci/apps/demo-api/Jenkinsfile`](../ci/apps/demo-api/Jenkinsfile) has four
   lines. Everything else is in the library. That is the whole point of a shared
   library: 50 teams, one place to fix the pipeline.
2. [`vars/standardPipeline.groovy`](../ci/shared-library/vars/standardPipeline.groovy):
   the declarative pipeline. Stages, `when { branch 'main' }`, `post`.
3. [`vars/buildImage.groovy`](../ci/shared-library/vars/buildImage.groovy): ECR
   login with no stored credentials, rootless BuildKit, and the two bugs from
   drill 18 in its comments.
4. [`vars/deployToEks.groovy`](../ci/shared-library/vars/deployToEks.groovy):
   why `rollout status` matters more than `apply`.
5. [`ci/jenkins/values.yaml`](../ci/jenkins/values.yaml): JCasC. The library,
   the job and the agent templates are all config, not clicks.
6. [`catalog-info.yaml`](../catalog-info.yaml): what Backstage shows.

## Things to practise until they are boring

- Create a branch, change a test so it fails, push. Watch the branch build run
  Test and **skip** push and deploy. Then fix it.
- Change the `/` response, merge to main, watch it deploy. `curl` it.
- Every scenario in drill 18. Break it, read the error, *then* look at the fix.
- `kubectl auth can-i ... --as system:serviceaccount:jenkins:jenkins-agent`
- Delete the Jenkins controller pod. It comes back with the same job and library,
  because both come from JCasC and the PVC.
- Add a component to `catalog-info.yaml`, push, and wait for Backstage to pick
  it up (it re-reads locations on a schedule).

## Questions you will get, and the answer that sounds mid-level

**"How do you share pipeline code across teams?"** A global shared library,
loaded by name and pinned to a version: `vars/` for steps, `src/` for classes,
`resources/` for files such as pod templates. Teams get a 4-line Jenkinsfile.
Libraries configured by an admin are *trusted* and run outside the Groovy
sandbox, which is why logic belongs there and not in Jenkinsfiles. Pin teams to
a tag, because a bad commit to the library's `main` breaks every pipeline at once.

**"Declarative or scripted?"** Declarative for pipelines, because it is
structured, validated and readable, with `script {}` blocks or library steps
where real logic is needed. Scripted is Groovy all the way down, which is
flexible and harder to review.

**"How do you build images inside Kubernetes?"**
- `docker.sock` mount: impossible on EKS ≥ 1.24 (no Docker on nodes), and root
  on the node anyway.
- DinD: works, needs `privileged: true`.
- kaniko: archived by Google in June 2025. Know it, but don't propose it.
- **Rootless BuildKit**: what this lab uses. No privileged container. It needs
  seccomp/AppArmor `Unconfined` and `--oci-worker-no-process-sandbox`, which is a
  trade worth being able to state.

**"How does the pipeline authenticate to ECR?"** With no stored secret. The
agent mints a 12-hour token from an IAM role. Here that is the node role, which
means *every* pod on the node can push. The production answer is **IRSA / EKS
Pod Identity**: the role is bound to the agent's service account only.

**"A deploy failed. What do you do?"** Find the first red stage, not the last
line. Decide which layer produced the message (Jenkins, registry, IAM, the
Kubernetes API, kubelet or the app), then check it from that layer's own tool:
`aws sts get-caller-identity`, `kubectl auth can-i`, `kubectl describe pod`,
`kubectl get events`. Drill 18 is six worked examples.

**"Why ECS for one thing and EKS for another?"** Pick the smallest platform
that fits. A single stateful vendor container with no scaling story does not
need Kubernetes: on ECS Fargate it is a task definition and a service
(`terraform/ecs`). Two costs showed up here. First, **no log driver without an
execution role**, so the app died inside a container that stayed RUNNING and
nothing said so. Running the same image as a pod on EKS and reading `kubectl
logs` found three separate start-up failures in turn. Second, **platform
limits you cannot see**: the playground's compliance job deleted the 2 vCPU
service minutes after a successful apply. CloudTrail (`lookup-events`) showed
who did it. Both are good answers to "tell me about a time something failed
silently".

**"What is Backstage for?"** So that other teams can answer *who owns this,
where is its pipeline, how do I start a new one* without asking the platform
team. It has a catalog (from `catalog-info.yaml` in each repo), software
templates and TechDocs. Plugins are compiled in, so you build your own image.
That is the main operational difference from Jenkins.

**"What would you watch in Datadog for this?"** Agent DaemonSet plus cluster
agent, with consistent `env`/`service`/`team` tags (untagged data cannot be
queried), and monitors on deployment replicas-unavailable, pod restarts, and
build failure rate. The trap on EKS is that the kubelet cert is not valid for
the address the agent dials, so with TLS verification on you get **no pod
metrics and no error in the UI**. See `ci/datadog/values.yaml`.

**"How do you make Terraform reviewable and safe?"** Plan in CI on the PR and
post the plan, with apply only from main. Use remote state with locking (S3
native locking here), pinned providers, and no secrets in variables. When a
resource already exists, `import` it instead of recreating it. That happened
here with the ECS cluster.
