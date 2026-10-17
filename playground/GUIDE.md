# Interview prep: start here

This is a practice plan for a **DevOps / CI-CD platform engineer** interview
(Jenkins shared pipelines, Kubernetes, Terraform, AWS EKS/ECR/IAM, Artifactory,
Backstage, monitoring, supporting developers). You practise by **fixing real
incidents** on real tools, against a clock, and then **explaining** them. That
second part is the interview.

One sitting is about 45 minutes. The plan below is seven sittings. You only need
a browser and a terminal on the Mac; everything runs on the home lab
(`homelab-1`).

---

## 0. Before the first session (10 minutes)

**1. Open the start page:** http://home.192.168.0.23.nip.io (or http://192.168.0.23/).
Every tile should have a green dot. Bookmark it: every tool is one click away.

| Tool | Address | Login |
|---|---|---|
| Start page | http://home.192.168.0.23.nip.io | none |
| Playground Jenkins (the drills) | http://192.168.0.23:30094 | admin / shared password |
| Playground Gitea (the drills' git) | http://192.168.0.23:30300 | admin / shared password |
| Platform: Argo CD | http://argocd.192.168.0.23.nip.io | admin / shared password |
| Platform: Grafana | http://grafana.192.168.0.23.nip.io | admin / shared password |
| Platform: Jenkins | http://jenkins.192.168.0.23.nip.io | admin / shared password |
| Platform: Artifactory | http://artifactory.192.168.0.23.nip.io | admin / shared password |
| Platform: Backstage | http://backstage.192.168.0.23.nip.io | guest |
| Kubernetes UI: Headlamp | http://headlamp.192.168.0.23.nip.io | admin / shared password (once) |

The **shared password** is the same for every tool; ask whoever runs the lab (it is
never written in this repo).

There are two Jenkins: the **playground** one (port 30094) is where the drills
happen; the **platform** one (`jenkins.` address) is part of the home-lab
platform you will give a tour of on day 5.

**2. Connect your Mac** (once). Nothing gets installed: everything runs on the lab,
your Mac only needs its built-in `ssh` and a browser. The lab owner must have added
your **public** key first (send them `~/.ssh/id_ed25519.pub`, never the file without
`.pub`). On the home Wi-Fi, in Terminal:

```bash
curl -fsSL -o join.sh https://raw.githubusercontent.com/alecuvalentin22/aws-kodekloud-playground/feat/playground/homelab/mac/join.sh
bash join.sh
```

It sets up SSH for the lab (and pins the lab's identity, so there is no "are you
sure?" question), checks the connection, and ends with "You are set up". Then:

```bash
ssh homelab-1-wsl                                   # you are now on the lab box
git -C ~/platform-lab pull                          # latest drills
play doctor                                         # every line should be ✓
```

If something is ✗: `~/platform-lab/playground/setup/up.sh` (safe to re-run), then
`play doctor` again. Still red? See "When something is broken" at the bottom.

---

## 1. How one drill goes

```text
play start 01     a ticket from a "developer" appears. The clock starts.
                  Investigate with the real tools: Jenkins console, git log, kubectl...
                  Your working copies are in ~/platform-playground (git pull first).
play hint         stuck? -15 points each, up to three, from "where to look" to "what to do"
play check        not fixed yet: says what is still wrong, clock keeps running
                  fixed: you get a score (100 - hints - minutes over par - penalties)
play close        write the reply to the developer + your STAR story (saved to the journal)
play reveal       the root cause, the proper fix, and "say this in the interview"
play reset        back to a clean baseline before the next one
```

**The one rule: talk out loud the whole time.** Say what you are checking and
why, what you expected, and what you saw. In the interview that narration is what
gets scored, not the fix.

`play check` is strict on purpose: "the build is green" is not always "it is
fixed". Penalties are for fixes that would hurt you at work (force-pushing a
shared branch, giving away too much access, and so on).

---

## 2. The plan

Run the **local** drills on the box (`ssh homelab-1-wsl`, then `play ...`).
Run the **home-lab** drills (21, 24) from a **Mac** terminal in this repo
(`playground/play ...`): they break the home lab itself, so they drive it from outside.

### Day 1: Jenkins pipelines

| Drill | Ticket | Par | Practise saying |
|---|---|---|---|
| 01 | "Copied the Jenkinsfile from the wiki" | 8 min | why a build can fail before its first stage, and how shared-library versions are chosen |
| 02 | "Build says rolled back, feature not live" | 12 min | why a red pipeline can be the system protecting you; readiness vs running |

After both: `play close` on each, then `play reveal` on the harder one and compare
your words with the "say this in the interview" part.

### Day 2: Terraform and Kubernetes

| Drill | Ticket | Par | Practise saying |
|---|---|---|---|
| 08 | "Remove one bucket, not three" | 20 min | reading a `terraform plan` as a review, and changing code without destroying things |
| 03 | "No pods, no errors, nothing deployed" | 15 min | where Kubernetes hides the reason when nothing happens |

### Day 3: Jenkins agents and safety

| Drill | Ticket | Par | Practise saying |
|---|---|---|---|
| 05 | "Every build stuck waiting" | 15 min | how build agents get scheduled, and why one change hit everyone |
| 04 | "Just approve my script, please" | 15 min | saying **no** to a developer while still solving their problem |

### Day 4: Blast radius and access

| Drill | Ticket | Par | Practise saying |
|---|---|---|---|
| 07 | "Every team red at 9:05" | 20 min | fixing a shared library that broke every team: revert vs force-push, how to release safely |
| 06 | "Can our pipeline deploy to staging?" | 25 min | least privilege, proving access with `kubectl auth can-i`, the second bug behind the first |

### Day 5: Running the platform (home lab)

From a Mac terminal, in this repo:

```bash
playground/play start 21      # "Jenkins down, nobody can deploy", par 20 min
```

Then `play check`, `play close`, `play reset`, and:

```bash
playground/play start 24      # "Someone deleted payroll; it was never in git", par 30 min
```

Both write a short answer file the ticket names (`~/platform-playground-homelab/answers/<id>.md`):
what you found and why. `play check` reads it. Drill 24 is a **real** restore: the
Kubernetes API goes away briefly while you do it. That is expected.

Then give the **platform tour** (section 3) out loud, as if to an interviewer.

### Day 6: AWS (one KodeKloud session, about 3 hours)

Real ECR, IAM, S3, VPC and EKS. Start a KodeKloud AWS playground first; its keys go
in `~/.config/platform-lab/aws-lab-creds.env` (mode 600, never `~/.aws/credentials`).
**The AWS drills run on the lab box** (it has the AWS CLI, `make` and kubectl). The
keys get there one of two ways: the lab owner runs `homelab/mac/send-aws.sh` on their
Mac (keys, EKS kubeconfig and the Jenkins/Gitea logins, then three checks), or you paste
your own with `playground/setup/aws-creds.sh` on the box (hidden, validated, never
`~/.aws`). Then `ssh homelab-1-wsl` and play from there; the EKS lab must already be up.

```bash
make state && make eks && make kubeconfig  # the EKS cluster (~20 min: start it first)
playground/setup/up-aws.sh                 # Gitea + Jenkins on EKS, ECR, a first green build
playground/play start 13                   # then the table below
```

**Part 1, CI/CD on EKS** (Jenkins agents on EKS pushing to ECR):

| Drill | Ticket | Par | Practise saying |
|---|---|---|---|
| 11 | "401 from ECR, and IAM is fine" | 20 min | what a 401 means vs a 403, and why "IAM is fine" can be true |
| 12 | "Security found a token in a build log" | 25 min | what you can and cannot undo after a secret leaks |
| 13 | "denied: not authorized to perform" | 20 min | least privilege on AWS, reading an IAM denial |
| 14 | "Pentest: any pod can push to ECR" | 40 min | node role vs per-pod identity (IRSA), and proving the fix |
| 16 | "New pods can't pull; the image is gone from ECR" | 20 min | lifecycle policies, and why running pods hide the problem |

**Part 2, cloud operations** (no Jenkins needed; pick the ones that match the
interview, 3-4 per session). Each one is a real incident on the AWS account:

| Area | Drills |
|---|---|
| Terraform | 15 state lock, 18 drift from a console change, 63 adopting a hand-made bucket (`import`) |
| IAM / STS | 19 IRSA trust mismatch, 68 CI can't assume the deploy role, 72 session duration and role chaining |
| S3 | 61 explicit deny in a bucket policy, 62 recovering with versioning, 75 ACLs disabled, 77 policy prefixes |
| EKS | 17 volume pinned to an availability zone, 66 pod DNS policy, 69 full volume resized online, 74 Service selector matches no pods |
| Network | 71 blocking one IP with a network ACL, 73 a stranded security-group reference, 76 a subnet on the wrong route table |
| Ops | 64 an alarm that never fired (monitoring, like Datadog monitors), 65 ECR immutable tags, 67 who opened the bucket (CloudTrail forensics) |

`play` refuses to start an AWS drill with under 20 minutes left in the session.
Also read `STORY-AWS.md` (repo root): the EKS "17 pods per node" story is a classic
interview question and cannot be a drill. Every AWS drill above was played live on
2026-10-17; if one misbehaves on a new account, note what happened: that is the
account's rules or a drill bug, not you.

### Day 7: Mock interview

`play start` with **no number**: a random drill you have not solved, and you are
not told which (like real life). Do two, talking out loud, ideally to a friend
or a recording. Then re-read your journal (`~/platform-playground/journal/` on the
box) and practise each STAR story in under two minutes.

After that: replay anything under 80 points (`play list` shows your best scores).

---

### After the seven days: more practice

| Track | Drills / exercises | Where |
|---|---|---|
| Jenkins: pipelines II | 09 write and release a library step, 41-48 (swallowed failures, workspaces between stages, approvals that hold agents, credential scope, triggers, multibranch discovery, the parameter trap, downstream jobs) | the box |
| Jenkins: static agents | exercise `exercises/static-vs-dynamic-agents/`, then 51-53 (agent offline, leftovers, disk full); start with `playground/setup/static-agent.sh up` | the box |
| Jenkins job types | exercises `exercises/jenkins-job-types/` (freestyle .. Job DSL, 15 Q&A) and `exercises/full-cicd/` (staging, approval, prod, automatic rollback) | the box |
| GitHub | 31-34 on your own GitHub account (`playground/setup/GITHUB.md`) | anywhere with your token |
| Nice-to-haves | exercises `exercises/artifactory/` and `exercises/backstage/` | any computer on the Wi-Fi |

**The board:** every drill and exercise is a ticket on the Tracker (start page
tile, Jira-like). `play start` moves it to In Progress, a solved `play check` to
Done with your score, `play close` posts your write-up, `play reveal` marks it
"Needs replay". The tickets say exactly how to run each drill.

## 3. The platform tour (day 5, and "walk me through something you built")

Open the start page and walk through it. For each stop, one or two sentences:

1. **Argo CD**: everything on the cluster comes from git (one "app of apps",
   `homelab-platform`, owns all the others). Show an app's history, and what
   happens if someone changes something by hand (Argo puts it back).
2. **Grafana**, folder *Home lab*: the *Uptime* dashboard checks every tool twice,
   from inside the cluster and through the address people use. Why both? (If only
   the outside check fails, the app is fine and the problem is in front of it.)
3. **Platform Jenkins**: a pipeline built on a shared library: build, push the
   image to the registry, deploy `demo-api`. Why a shared library: one place to
   fix things for every team. Drill 07 is what happens when that goes wrong.
4. **Artifactory** (the free OSS edition): what it can and cannot do (Maven and
   generic repositories yes; Docker images no, so images go to a plain registry).
   Knowing a tool's limits is a good interview answer.
5. **Backstage**: the developer portal. The service catalog comes from
   `catalog-info.yaml` files in git.
6. **Headlamp**: the cluster in a browser: nodes, pods, logs. Explain what you
   would and would not give developers access to.
7. **Backups**: the cluster's database (etcd) is snapshotted every 6 hours and
   copied off the machine. Drill 24 is you using one.

---

## 4. Cheat sheet

| I want to... | Command |
|---|---|
| see all drills and my best scores | `play list` |
| see what is running | `play status` |
| start a random drill from one area | `play start --track jenkins` (or `kubernetes`, `terraform`) |
| my history | `play score` |
| look at the playground cluster | `kubectl get pods -A` (on the box) |
| look at the home-lab cluster | `export KUBECONFIG=$PWD/homelab/generated/rke2-lan.kubeconfig` on the Mac, or Headlamp |

## When something is broken

- **Nothing answers in the morning or after a break?** The lab sleeps at night and when idle:
  `ssh homelab-1-wsl homelab-power wake`, then ~15-20 min.
- **A tool's tile is red on the start page, right after the PC rebooted:** wait.
  Everything comes back on its own; Artifactory is last (about 20 minutes).
- **`play doctor` shows ✗:** `~/platform-lab/playground/setup/up.sh` on the box.
- **A drill seems stuck in a broken state:** `play reset`.
- **Nothing answers at all:** is the PC on, and on the home Wi-Fi? A new router
  changes its address: `homelab/windows/START-HERE.md`, section "New router?".

More detail on everything: `playground/README.md` (the game) and
`homelab/README.md` (the home lab).
