# AGENTS.md: operating the home lab (for AI assistants)

Give this file to any AI assistant that has to run, check or change the home lab, the
interview playground or the tracker board. It is the map; the details live in the files it
links. For the AWS/EKS lab and the KodeKloud rules, read [`../AGENTS.md`](../AGENTS.md) too.

**The repo is PUBLIC** (github.com/alecuvalentin22/aws-kodekloud-playground, branch
`feat/playground`). Never write a password, token or key into any tracked file. The tools
share one admin password: ask the owner for it, pass it via an environment variable
(`HOMELAB_ADMIN_PASSWORD`), and never echo it.

---

## 0. Check the state first. The lab may be stopped on purpose

```bash
lab-status                                  # zsh function on the owner's Mac
ssh homelab-1-wsl homelab-power status      # same, from anywhere with the SSH config
```

- `HELD: ...` means the owner stopped it **until further notice** (`lab-stop`). **Do not
  start it without asking the owner.** To start: `lab-start` (cluster ~3 min, web tools
  ~15-20 min, Artifactory last).
- `asleep` without HELD means the night/idle timers put it to sleep (sleeps 01:00, wakes
  07:30 Europe/Bucharest, and sleeps after 3 h idle). Wake it: `ssh homelab-1-wsl homelab-power wake`.
- "Nothing answers" is usually just this. Check it before debugging anything.

Functions: [`mac/lab-functions.zsh`](mac/lab-functions.zsh) (sourced from the owner's `~/.zshrc`).
Rules and timers: [`README.md`](README.md), section "Sleep and wake".

## 1. What it is, and how to reach it

```
Mac ──ssh──▶ homelab-1      Windows 11 laptop, OpenSSH, admin PowerShell, key-only, LAN-only
               └─ProxyJump─▶ homelab-1-wsl   Ubuntu 24.04 in WSL2 (user lab, passwordless sudo)
                               ├─ Incus/KVM VMs rke2-s1 (10.77.0.31, server), rke2-a1, rke2-a2
                               │    └─ RKE2 + Argo CD platform (homelab/platform/)
                               ├─ Docker: kind "playground" (Gitea + Jenkins + registry) for the drills
                               └─ HAProxy: LAN ports 80/443/6443/30094/30095/30300 -> the above
```

| Thing | Where |
|---|---|
| LAN address | `192.168.0.23` (source of truth: [`lan.env`](lan.env); new router? [`windows/START-HERE.md`](windows/START-HERE.md) "New router?", then `mac/readdress.sh <ip>`) |
| Start page (every tool) | http://home.192.168.0.23.nip.io |
| Tools | `http://<tool>.192.168.0.23.nip.io`: argocd, grafana, jenkins, artifactory, backstage, registry, headlamp, tracker. Login `admin` + the shared password (Plane: `admin@homelab.local`) |
| Kubernetes API (home-lab RKE2) | `export KUBECONFIG=<repo>/homelab/generated/rke2-lan.kubeconfig` (git-ignored, on the owner's Mac) |
| Playground (kind) on the box | Jenkins `:30094`, Gitea `:30300`, demo-api `:30095`; logins in `~/.local/state/platform-lab-playground/creds.env` on the box |
| SSH config | owner: `~/.ssh/config.d/homelab`; others: `mac/join.sh` writes `~/.ssh/config.d/homelab-join` and pins the host keys |

Only the **home Wi-Fi** (192.168.0.0/24) can reach it. Plain HTTP, on the owner's choice.

## 2. Common jobs

| Goal | Do this |
|---|---|
| Start / stop / status | `lab-start` / `lab-stop` / `lab-status` (section 0) |
| Platform health | `kubectl -n argocd get applications` (16 apps, all Synced/Healthy) and `kubectl get pods -A \| grep -v Running` |
| Change a platform tool | edit `homelab/platform/apps/*.yaml` (chart + version) or `values/<tool>.yaml`, commit, push to `feat/playground`; Argo CD syncs. New namespace or Helm repo: add it to `platform/project.yaml` and `kubectl apply -f` it by hand. See [`platform/README.md`](platform/README.md) |
| Playground healthy? | `ssh homelab-1-wsl '~/platform-lab/playground/play doctor'` (rebuild: `.../playground/setup/up.sh`) |
| Update the box's checkout | `ssh homelab-1-wsl 'cd ~/platform-lab && git pull --ff-only origin feat/playground'` |
| Change box config (tools, timers, HAProxy...) | Ansible from the Mac, **only the tag you need**: `ansible-playbook -i homelab/inventory.ini playbooks/homelab.yml --tags <tag>` (e.g. `power`, `awscli`, `lan_ingress`, `backups`). See [`README.md`](README.md) |
| Let someone else in | `mac/authorize-key.sh their_key.pub [--full\|--remove]`; they run `mac/join.sh` |
| AWS drills from the box | owner: `mac/send-aws.sh [--creds-only]`; or `playground/setup/aws-creds.sh` on the box (keys pasted, never `~/.aws`) |
| Backups | etcd snapshots every 6 h, copied to WSL and `C:\homelab-backups\etcd`; `mac/backup-status.sh` |
| Board (Plane tracker) | `playground/tracker/sync.sh --dry-run`, then `sync.sh` (idempotent: re-run = 0 created, 0 updated) |

## 3. The interview playground

- Engine: [`../playground/play`](../playground/play): `start | hint | check | close | reveal | reset | status | list | doctor`.
  Drills in [`../playground/drills/NN-*/`](../playground/drills) (contract: drill.env, ticket.md,
  hints.md, solution.md, break.sh, check.sh, reset.sh). Candidate's guide: [`../playground/GUIDE.md`](../playground/GUIDE.md).
- Tiers by `NEEDS=` in drill.env: `local` (the box's kind playground), `homelab` (21, 24: run
  from the owner's Mac), `aws` (11-19, 61-77: a live KodeKloud session), `github` (31-34).
- **One drill at a time per state dir.** `play` keeps one current drill in
  `~/.local/state/platform-lab-playground/current.env`. Don't start a drill while the candidate
  is playing (`play status` on the box).
- **Don't touch the candidate's board while testing:** run `TRACKER_ENV=/nonexistent play ...`,
  or `play start/check/close/reveal` will move her tickets in Plane.
- Several agents verifying at once: take the box lock `mkdir ~/.pg-verify.lock` (on the box;
  `rm -rf` it when done), or use a separate `PLAYGROUND_STATE=...` lane for AWS drills, and
  then **never** `play reset` on the AWS tier (it runs every AWS drill's reset.sh).
- After verifying, move your score lines from `scores.tsv` into a `scores.verification-*.tsv`
  so the candidate's scoreboard stays clean.

## 4. Rules that cost real damage when ignored

1. **Never `git commit -a` / `git add -A`** when others (agents) might have uncommitted work:
   `git add <exact paths>`. It once swept unreviewed work into a pushed commit.
2. **No secrets in files or output**: no `bash -x` on scripts that load credentials (it has
   printed keys twice).
3. **Don't run the whole Ansible role casually**: use tags. `--tags power` also re-enables the
   timers and VM autostart, which **undoes a `lab-stop` hold**.
4. **KodeKloud AWS**: read [`../docs/kodekloud-limits.md`](../docs/kodekloud-limits.md) and
   [`../AGENTS.md`](../AGENTS.md). Violations are recorded against the owner's account. The
   IAM window is 3 h. Some calls are denied per account (e.g. iam:DeletePolicy, UpdateAssumeRolePolicy,
   Lambda PassRole): probe with invalid input or `--dry-run`, don't guess.
5. **Versions**: pin exactly, at least two weeks old, and say the release date in a comment.
6. **zsh traps** in one-liners: variables don't word-split, and `$VAR:x` is a zsh modifier
   (`${VAR}:sub`, not `$VAR:sub`). Use `bash -c '...'` for anything non-trivial.

## 5. Where to read more

- [`README.md`](README.md): the home lab end to end (bootstrap, WSL, VMs, RKE2, LAN access,
  backups, sleep/wake, verified-on-hardware table).
- [`platform/README.md`](platform/README.md): every platform tool, its Secrets, the Argo traps.
- [`../playground/README.md`](../playground/README.md): the game and every drill.
- [`../terraform/README.md`](../terraform/README.md): which Terraform stacks are live, and a fresh KodeKloud account in order.
- [`../ci/apps/demo-api/chart/demo-api/README.md`](../ci/apps/demo-api/chart/demo-api/README.md): the demo-api Helm chart.
