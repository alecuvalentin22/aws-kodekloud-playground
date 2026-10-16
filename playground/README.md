# Playground: interview drills for a CI/CD platform role

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

Suggested first pass: 01 → 02 → 08 → 03 → 05 → 04 → 07 → 06, then
`play start` with no ID until nothing is left, then replay for score.

## What a 45-minute session looks like

1. `play doctor` (and `up.sh` if anything is red).
2. Two drills. Talk out loud while you debug — say what you are checking and
   why. That is the interview.
3. `play close` on both. Re-read yesterday's journal entries.
4. `play reveal` on the one you found hardest, and compare.

## AWS tier (needs a playground session)

Some things only exist on AWS. These run against the EKS lab
(`make eks && make jenkins`, see `docs/ci-track.md`) and are written up in
`drills/18-jenkins-pipeline-failures.md`; they are not yet `play` drills:

- ECR push **401 vs 403**, and the token that leaked into the console (§1, §1b, §2)
- **IRSA / Pod Identity** for the agent instead of the node role
- the **17-pods-per-node** ENI ceiling (`STORY-AWS.md`)
- Terraform **state lock** in S3 (`drills/10-terraform-state.md`)
- Artifactory as a pip/maven remote (Artifactory runs on GCP: `terraform/gcp-artifactory`)

## When the playground itself breaks

```bash
play doctor                          # which component is down
kubectl --context kind-playground get pods -A
playground/setup/up.sh               # safe to re-run
playground/setup/down.sh             # delete the cluster + registry (keeps creds and scores)
```
