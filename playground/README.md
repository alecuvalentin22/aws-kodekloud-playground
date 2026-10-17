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

## AWS tier: drills 11–14 (needs a KodeKloud session)

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

## When the playground itself breaks

```bash
play doctor                          # which component is down
kubectl --context kind-playground get pods -A
playground/setup/up.sh               # safe to re-run
playground/setup/down.sh             # delete the cluster + registry (keeps creds and scores)
```
