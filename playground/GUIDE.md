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
| Playground Jenkins (the drills) | http://192.168.0.23:30094 | admin / parola |
| Playground Gitea (the drills' git) | http://192.168.0.23:30300 | admin / parola |
| Platform: Argo CD | http://argocd.192.168.0.23.nip.io | admin / parola |
| Platform: Grafana | http://grafana.192.168.0.23.nip.io | admin / parola |
| Platform: Jenkins | http://jenkins.192.168.0.23.nip.io | admin / parola |
| Platform: Artifactory | http://artifactory.192.168.0.23.nip.io | admin / parola |
| Platform: Backstage | http://backstage.192.168.0.23.nip.io | guest |
| Kubernetes UI: Headlamp | http://headlamp.192.168.0.23.nip.io | admin / parola (once) |

There are two Jenkins: the **playground** one (port 30094) is where the drills
happen; the **platform** one (`jenkins.` address) is part of the home-lab
platform you will give a tour of on day 5.

**2. Check the playground** from a Mac terminal:

```bash
ssh homelab-1-wsl                                   # you are now on the lab box
git -C ~/platform-lab pull                          # latest drills
~/platform-lab/playground/play doctor               # every line should be ✓
```

If something is ✗: `~/platform-lab/playground/setup/up.sh` (safe to re-run), then
`play doctor` again. Still red? See "When something is broken" at the bottom.

**3. Make `play` short to type** (on the box, once):

```bash
echo 'alias play=~/platform-lab/playground/play' >> ~/.bashrc && source ~/.bashrc
```

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

Real ECR and real IAM on EKS. Start a KodeKloud AWS playground first; the
session's credentials go in `~/.config/platform-lab/aws-lab-creds.env` on the Mac
(mode 600, never `~/.aws/credentials`). Then, from the Mac:

```bash
make eks                                   # the EKS cluster (takes a while: start it first)
playground/setup/up-aws.sh                 # Gitea + Jenkins on EKS, ECR, a first green build
playground/play start 11                   # then 12, 13, 14
```

| Drill | Ticket | Par | Practise saying |
|---|---|---|---|
| 11 | "401 from ECR, and IAM is fine" | 20 min | what a 401 means vs a 403, and why "IAM is fine" can be true |
| 12 | "Security found a token in a build log" | 25 min | what you can and cannot undo after a secret leaks |
| 13 | "denied: not authorized to perform" | 20 min | least privilege on AWS, reading an IAM denial |
| 14 | "Pentest: any pod can push to ECR" | 40 min | node role vs per-pod identity (IRSA / Pod Identity), and proving the fix |

`play` refuses to start an AWS drill with under 20 minutes left in the session.
Drills 13 and 14 have not been played live yet: if one misbehaves, note what
happened; that is a bug in the drill, not you. Also read `STORY-AWS.md` (repo
root): the EKS "17 pods per node" story is a classic interview question and cannot
be a drill.

### Day 7: Mock interview

`play start` with **no number**: a random drill you have not solved, and you are
not told which (like real life). Do two, talking out loud, ideally to a friend
or a recording. Then re-read your journal (`~/platform-playground/journal/` on the
box) and practise each STAR story in under two minutes.

After that: replay anything under 80 points (`play list` shows your best scores).

---

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

- **A tool's tile is red on the start page, right after the PC rebooted:** wait.
  Everything comes back on its own; Artifactory is last (about 20 minutes).
- **`play doctor` shows ✗:** `~/platform-lab/playground/setup/up.sh` on the box.
- **A drill seems stuck in a broken state:** `play reset`.
- **Nothing answers at all:** is the PC on, and on the home Wi-Fi? A new router
  changes its address: `homelab/windows/START-HERE.md`, section "New router?".

More detail on everything: `playground/README.md` (the game) and
`homelab/README.md` (the home lab).
