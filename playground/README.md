# Playground: interview drills for a CI/CD platform role

> **Preparing for an interview? Start with [GUIDE.md](GUIDE.md)**: a 7-session plan,
> the logins, and what to say out loud. This page is the reference for the game itself.

A game for practising the job, not reading about it. Each drill is an
**incident**: something gets broken the way it breaks at work, you get a ticket
from the developer who hit it, and a clock runs until `play check` confirms it
is *really* fixed — not just green.

It is built for one job description in particular (Jenkins shared pipelines,
GitHub, AWS/EKS, Docker/ECR, Terraform, Artifactory, Backstage, Datadog,
supporting developers), and runs the **same Jenkins, shared library, agent pod
and app as the EKS lab** in this repo, on your laptop, with no cloud account.

## Start

```bash
playground/setup/up.sh        # ~10 min the first time; idempotent
playground/play list
playground/play start         # a random drill -- you are not told which
```

You need Docker (6–8 GB of memory is comfortable; 4 GB works), `kubectl`,
`helm`, `git`, `jq`, `terraform`. `up.sh` downloads a pinned, checksum-verified
`kind` into `~/.local/state/platform-lab-playground/bin`, and changes nothing
else on your machine.

## What you get

| | Local stand-in | At work / in the EKS lab |
|---|---|---|
| Jenkins | the same chart and JCasC (`ci/jenkins/values.yaml`) + a small local overlay | Jenkins on EKS |
| Shared library | `platform/platform-lib`, its own repo | `ci/shared-library` |
| App | `payments/demo-api`, a 4-line Jenkinsfile | `ci/apps/demo-api` |
| Git hosting | Gitea, http://localhost:30300 | GitHub |
| Registry | `kind-registry:5000` (localhost:5001) | ECR |
| Cluster | kind, context `kind-playground` | EKS |

Your clones live in `~/platform-playground/` — **work there**, like you
would in your own checkout. Teammates (the drills) push to the same repos, so
`git pull` first. Credentials are in `~/.local/state/platform-lab-playground/creds.env`.

The logins are `admin` on both Jenkins and Gitea. The passwords are generated
unless you choose one: with `PLAYGROUND_ADMIN_PASSWORD` set, the first `up.sh`
uses it for both, and `PLAYGROUND_ADMIN_PASSWORD=... setup/up.sh --set-password`
changes an existing playground (Jenkins via helm, Gitea via `gitea admin user
change-password`, the clones' credential store rewritten). It is only ever
written to `creds.env` (mode 600), never printed or committed.

## How a round goes

```text
play start            read the ticket. Clock starts.
  ...investigate with the real tools: Jenkins console, kubectl, git log...
play hint             -15 points each. Three per drill, from "where to look" to "what to do"
play check            not fixed? it says what is still wrong, clock keeps running
                      fixed? scored: 100 - hints - minutes over par - PENALTIES
play close            write the reply to the developer + the STAR story (saved to journal/)
play reveal           the root cause, the fix, and "say this in the interview"
play reset            everything back to baseline (as new commits, never a force-push)
```

**Penalties are the point.** Several drills have a fast fix that works and is
wrong: deleting another team's quota, approving a sandbox signature,
cluster-admin for the pipeline, force-pushing a shared main. The check
notices. Those are exactly the answers that lose an interview.

**`play close` is the other half.** The JD asks for someone who can "communicate
clearly with developers who may have limited platform context". Every drill
ends with you writing that reply. After a week, `~/platform-playground/journal/`
is a set of real incident stories in your own words.

## The drills

| ID | Ticket | Track | What it trains |
|---|---|---|---|
| 01 | "Copied the Jenkinsfile from the wiki" | jenkins | failures before the first stage; library versions |
| 02 | "Build says rolled back, feature not live" | kubernetes | readiness, `rollout status`, why a red pipeline can be the system working |
| 03 | "No pods, no errors, nothing deployed" | kubernetes | ReplicaSet events, ResourceQuota, surge math, other teams' policies |
| 04 | "Just approve my script, please" | jenkins | Groovy sandbox, controller vs agent, saying no but solving the need |
| 05 | "Every build stuck waiting" | jenkins | agent pods Pending, requests vs limits, shared pod templates |
| 06 | "Can our pipeline deploy to staging?" | kubernetes | least-privilege RBAC, `auth can-i --as`, a second bug hiding behind the first |
| 07 | "Every team red at 9:05" | jenkins | shared-library blast radius, revert vs force-push, pinning, release strategy |
| 08 | "Remove one bucket, not three" | terraform | count vs for_each, `moved` blocks, reading a plan as a review artifact |
| 09 | "Three copies of the same test block" | jenkins | writing a shared-library step (`vars/`, `call`), releasing it as a semver tag, testing it from a branch, pinning the pilot team, leaving other teams untouched |
| 41 | "Green build, but the bug shipped" | jenkins | a pipeline that cannot fail (`\|\| true`, `allowEmptyResults`), starting from what is running not the build colour, proving a gate with a failing-test canary |
| 42 | "Deploy stage can't find what Build produced" | jenkins | per-stage agents = new pod and workspace; stash/unstash vs env vs one agent vs registry; why the controller is not a hand-off |
| 43 | "Waiting for approval froze every team's builds" | jenkins | `input` inside an agent holds the pod; the cloud's agent cap; `agent none` + stage agents; timeouts; aborting parked builds instead of raising the cap |
| 44 | "Our deploy says credentials not found, payments' works" | jenkins | credential scope (global vs folder stores), a least-privilege move exposing a hidden dependency, a per-team credential, masking limits |
| 45 | "Pushes don't start builds anymore" | jenkins | how a multibranch job is triggered (indexing vs webhook vs polling), reading the scan log, "Suppress automatic SCM triggering", UI drift from JCasC |
| 46 | "My branch has no build" | jenkins | multibranch discovery: name filter vs Script Path, reading the scan log, fixing the branch not the shared job |
| 47 | "Release job asks no questions, deploys the default" | jenkins | parameters only take effect after a run, defaults vs null, `params` vs `env`, release jobs that fail on missing input |
| 48 | "Downstream deploy ran the wrong build" | jenkins | passing data between jobs, silently dropped parameters, deploying an exact tag/digest, never `latest` |
| 51 | "build-01 is offline and the release only runs there" | jenkins | static (inbound) agents: agent vs controller log, a stale node secret a restart can't fix, the "temporarily offline" flag, why not to move a host-bound job to the controller |
| 52 | "Works on the first build, fails on the second" | jenkins | static workspaces persist: ignored files survive checkout, a cache with no key, stale `dist/`, cleaning at the start vs only in `post`, why pods hide it |
| 53 | "Static agent disk full, every static build red" | jenkins | the disk-space monitor, ENOSPC, orphaned workspaces, `cleanWs` + build discarders, not loosening the threshold |

Home-lab tier (`NEEDS=homelab`: they break the home lab's RKE2 cluster itself, so
`play` runs them from the **Mac**, `playground/play start 21`; see "Playing on the home lab"):

| ID | Ticket | Track | What it trains |
|---|---|---|---|
| 21 | "Jenkins down, nobody can deploy" | kubernetes | a node dies: what moves, what cannot, and why |
| 24 | "Someone deleted payroll; it was never in git" | kubernetes | restoring from an etcd snapshot, and its blast radius |

Suggested first pass: 01 → 02 → 08 → 03 → 05 → 04 → 07 → 06, then
`play start` with no ID until nothing is left, then replay for score.

## What a 45-minute session looks like

1. `play doctor` (and `up.sh` if anything is red).
2. Two drills. Talk out loud while you debug — say what you are checking and
   why. That is the interview.
3. `play close` on both. Re-read yesterday's journal entries.
4. `play reveal` on the one you found hardest, and compare.

## AWS tier: drills 11–19 and 61–69 (needs a KodeKloud session)

Same game, same Gitea-and-Jenkins mechanics, but on the EKS lab with real
**ECR** and real **IAM**. Its state and clones are separate
(`~/.local/state/platform-lab-playground/aws`, `~/platform-playground-aws`),
so the two tiers never touch each other.

```bash
make eks                                  # the EKS lab (scripts/eks-up.sh)
playground/setup/up-aws.sh                # Gitea + Jenkins on EKS, ECR, baseline build
playground/play start 11                  # or: play start --tier aws
playground/play reset                     # an AWS drill resets via up-aws.sh --reset
```

| ID | Ticket | What it trains |
|---|---|---|
| 11 | "401 from ECR, and IAM is fine" | 401 = no credentials arrived; a file-permission bug that reads as IAM |
| 12 | "Security found a token in a build log" | `set -x` leaks, what you can and cannot revoke, cleaning history |
| 13 | "denied: not authorized to perform" | 403 = credentials arrived and were refused; least privilege on the node role |
| 14 | "Pentest: any pod can push to ECR" | node role vs IRSA / Pod Identity, and proving what a locked-down account allows |
| 15 | "Terraform says the state is locked" | stale S3 lockfile, who holds it, force-unlock vs -lock=false / deleting state, plan before apply |
| 16 | "New pods can't pull; the image is gone from ECR" | lifecycle policies (tagStatus, countType, rule priority), why running pods hide it, rebuild + keep-last-N per prefix |
| 17 | "Ledger DB stuck Pending after the node went away" | EBS is zonal and the PV pins the pod to its AZ; restore capacity in that AZ or snapshot-and-restore elsewhere; never delete the PVC; node group per AZ, and EFS for shared files |
| 18 | "Terraform plan wants to delete a rule nobody knows about" | drift from console changes in an incident: read the plan, `plan -refresh-only`, the actor in CloudTrail, decide each change (remove the open SSH rule, don't codify it, no `ignore_changes`), then the unrelated change and a clean plan |
| 19 | "Reports service: AccessDenied on S3, but the role has the permission" | IRSA trust debugging: the denied call is sts:AssumeRoleWithWebIdentity, not s3; compare the pod's ServiceAccount with the trust's `sub`/aud; fix the wrong side without widening trust or touching the node role |
| 61 | "Upload job: AccessDenied, and our IAM policy allows s3:PutObject" | "explicit deny in a resource-based policy": a bucket-policy Deny beats any IAM allow; two Denies (SSE header, TLS) behind one message; fix the client, never weaken the guardrail or disable TLS verification |
| 62 | "The release manifest is gone, and the one there now is wrong" | S3 versioning: delete markers vs versions, restoring the RIGHT version forward with copy-object, why a laptop re-upload is not recovery |
| 63 | "Terraform wants to create a bucket that already exists" | adopting hand-made infra: import blocks for the bucket and its versioning, config that matches reality (tags, versioning), reading the plan before apply, never delete-and-recreate |
| 64 | "The error-rate alarm never fired during the outage" | monitoring: metric identity = namespace + name + exact dimensions (case-sensitive), TreatMissingData and why a green alarm can be blind, proving an alarm with real datapoints instead of set-alarm-state, CloudWatch here / Datadog in the JD (CloudWatch only, no EKS needed beyond the preflight) |
| 65 | "Hotfix release won't push: the tag already exists" | ECR tag immutability: why reused version tags and `latest` are dangerous, immutable repos as a supply-chain guardrail, unique tags (version + build id or sha), deploying by digest |
| 66 | "checkout can't find ledger: 'Name or service not known'" | Kubernetes DNS on EKS: how `dnsPolicy` (ClusterFirst / Default / None / ClusterFirstWithHostNet) builds resolv.conf, CoreDNS vs the VPC resolver, diagnosing with resolv.conf + getent, tuning ndots via `dnsConfig` instead of bypassing cluster DNS |
| 68 | "CI can't assume the deploy role since the security review" | role trust for CI outside AWS: the exact principal + `sts:ExternalId`, one error message for two causes, never trusting the account root or `*`; on this account changing trust means re-creating the role |
| 71 | "Block the scanner hammering our API, without taking anyone else down" | security groups (stateful, allow-only) vs network ACLs (per subnet, stateless, ordered, deny): the deny-after-allow trap, ephemeral return ports, blocking a /32 not a range |

`preflight-aws.sh` refuses to start a drill with expired creds or under 20
minutes left in the 3-hour IAM window. These drills are `VERIFIED=no` until
they have been played live — see each `drill.env`. `up-aws.sh` takes over the
lab's `jenkins` Helm release; `make jenkins` puts the GitHub-sourced one back.

Not a drill, because it cannot be broken safely: the 17-pods-per-node ENI
ceiling (a node that joins wrong must be terminated). Talk it through from
`STORY-AWS.md` instead. Artifactory as a pip/maven remote runs on GCP
(`terraform/gcp-artifactory`) and is not wired into a drill yet.

## GitHub tier: drills 31–34 (needs a GitHub account and a token)

Real GitHub, Actions and GHCR, in three public repos created under YOUR account
(`playground-workflows`, `playground-demo-api`, `playground-search-api`). Setup,
token scopes and gotchas: [setup/GITHUB.md](setup/GITHUB.md).

```bash
# token in ~/.config/platform-lab/github-playground.env (mode 600), see GITHUB.md
playground/setup/up-github.sh --pin-actions   # once: tags -> commit SHAs
playground/setup/up-github.sh                 # creates the repos, waits for green CI
playground/play start 31                      # or: play start --tier github
playground/setup/up-github.sh --destroy       # delete the repos when done
```

| ID | Ticket | What it trains |
|---|---|---|
| 31 | "My PR has no checks" | `on:` triggers, path filters, why `pull_request_target` is the wrong fix |
| 32 | "Can't merge: 'build' expected" | branch protection, required check names vs matrix names, no admin override |
| 33 | "Every repo red after a shared workflow change" | reusable workflows, `@main` vs tag/SHA, revert forward, releases (analog of 07) |
| 34 | "Publish job: 403 pushing to GHCR" | `GITHUB_TOKEN` permissions, job-level least privilege, GHCR |

`preflight-github.sh` refuses to start unless the token works, the repos and clones
exist, `main` is at baseline and CI is green. `play reset` closes PRs, restores the
protection and puts `main` back to baseline as new commits. **The drills are
`VERIFIED=no` until played live**: built and tested offline (fixtures, local bare
repos), never yet against github.com.

## Exercises (guided, not scored)

Hands-on tours with a `check.sh` that verifies your work, for the tools the job
lists as nice-to-have. They run against the home-lab platform from any computer
on the Wi-Fi (`HOMELAB_ADMIN_PASSWORD` or a hidden prompt; nothing installed).

| Exercise | What you do | Talk about afterwards |
|---|---|---|
| [`exercises/artifactory/`](exercises/artifactory/README.md) | local + remote + virtual Maven repos, resolve through the proxy, deploy your own jar with checksums | why a proxy cache, local vs remote vs virtual, what OSS cannot do |
| [`exercises/backstage/`](exercises/backstage/README.md) | model a System + API + Component, register it from your public GitHub repo, find why a broken entity never appears | the catalog model, ownership, templates/TechDocs/plugins |
| [`exercises/jenkins-job-types/`](exercises/jenkins-job-types/README.md) | one job of every kind: freestyle, scripted vs declarative, multibranch, parameterized, upstream/downstream, matrix, Job DSL, triggers | when to use which; CPS; jobs as code; 15 interview Q&A |
| [`exercises/full-cicd/`](exercises/full-cicd/README.md) | build -> test -> image -> staging -> smoke test -> approval -> prod -> automatic rollback, in one declarative pipeline | why each stage exists; `input` outside agents; `stash`; `rollout undo` in `post { failure }` |
| [`exercises/static-vs-dynamic-agents/`](exercises/static-vs-dynamic-agents/README.md) | one pipeline on `static-01` and on a pod: persistence, queueing, cold start, offline behaviour, leftover credentials | static vs dynamic trade-offs and how each breaks (static agent: `setup/static-agent.sh up`) |

## Playing on the home lab

The whole game can run on the Ubuntu/WSL2 box (`homelab-1-wsl`) instead of on
your Mac: same `setup/up.sh`, same drills. `play` and your clones
(`~/platform-playground`) live **on the box**; your Mac is only a browser.

```bash
ssh homelab-1-wsl
git -C ~/platform-lab pull          # branch feat/playground
~/platform-lab/playground/setup/up.sh     # ~4 min with a fast link; 4 s when nothing changed
~/platform-lab/playground/play start 01   # then work in ~/platform-playground, as usual
```

From the Mac (or any device on the home Wi-Fi) the playground is at
http://192.168.0.23:30094 (Jenkins), http://192.168.0.23:30300 (Gitea) and
http://192.168.0.23:30095 (demo-api): HAProxy in WSL forwards those ports
(`homelab/mac/lan-ingress.sh`, `homelab/README.md` "LAN access"). The logins are
in `~/.local/state/platform-lab-playground/creds.env` **on the box** (admin / the
shared password, if it was set with `PLAYGROUND_ADMIN_PASSWORD`).

The **home-lab tier** (21, 24) is the exception: run those from the **Mac**,
`playground/play start 21`. They use `homelab/generated/rke2-lan.kubeconfig` and
`ssh homelab-1-wsl`, and the answer files go to `~/platform-playground-homelab/answers/`
on the Mac.

Off the Wi-Fi, an SSH tunnel still works (`-L 31094:localhost:30094 -L
31300:localhost:30300 -L 31095:localhost:30095 homelab-1-wsl`; other local ports than
30094/30300/30095 if the Mac's own playground holds them). Gitea's clone URLs on its
pages say `localhost:30300`; that is only text.

## Tracker: the drills as tickets on a Jira-like board

Every drill and exercise is also a ticket in **Plane** on the home lab
(http://tracker.192.168.0.23.nip.io/interview-prep/, login `admin@homelab.local` /
the shared password), grouped by the days of [GUIDE.md](GUIDE.md). `play start`
moves its ticket to In Progress, a solved `play check` to Done (score as a comment),
`play close` posts the journal entry, `play reveal` while running moves it to
Needs replay. Optional: without `~/.config/platform-lab/tracker.env` nothing changes,
and a tracker that is down only prints a warning. Token, `tracker/sync.sh` and the
hook: [tracker/README.md](tracker/README.md).

## When the playground itself breaks

```bash
play doctor                          # which component is down
kubectl --context kind-playground get pods -A
playground/setup/up.sh               # safe to re-run
playground/setup/down.sh             # delete the cluster + registry (keeps creds and scores)
```
