# What is verified, and how

Same rule as the repo's root `VERIFIED.md`: a claim is only as good as the run
behind it. Everything below was run on 2026-10-16, on a MacBook (Docker
Desktop, 4 CPU / 4 GB VM), kind v0.33.0, node v1.34.11, Jenkins chart 5.9.68.

## Setup

| | Result |
|---|---|
| `setup/up.sh` from nothing | green baseline; first run ~25 min, dominated by image pulls (`alpine/k8s` alone 1m54s) |
| `setup/up.sh` second run, after `seed.sh --force` and deleting the clones | **1m56s**, everything kept or re-cloned, baseline build #21 green |
| JCasC overlay on the EKS `values.yaml` | job, library and `PLATFORM_REGISTRY` all applied, no merge conflict with the chart's default config |
| rootless BuildKit in a kind pod → `kind-registry:5000` over HTTP | pushed `main-56d7e328-1`; node pulled it via `certs.d/kind-registry:5000/hosts.toml` |
| `curl localhost:30095/` | `{"app":"demo-api","version":"main-56d7e328-1"}` |
| test report from an app at the repo root | **3 passed** after the junit-path fix in `standardPipeline.groovy` (before: "No test report files were found") |

## Every drill, played end to end

Each was started with `play start NN`, the real failure observed, fixed from
`~/platform-playground` the way a candidate would, and scored by `play check`.
Error text in the solutions is pasted from these runs.

| Drill | Real failure observed | Fix played | `play check` |
|---|---|---|---|
| 01 | `ERROR: Could not resolve v2` (library ref) | pin `@v1.0.0` | 100 |
| 02 | new pod `CrashLoopBackOff` (liveness on the same `/healthz`), rolled back | `git revert` | 100 |
| 03 | ReplicaSet `FailedCreate ... exceeded quota: cost-guardrails ... limited: pods=2`, no pod object | `maxSurge: 0 / maxUnavailable: 1`, quota kept | 100 |
| 04 | `Scripts not permitted to use staticMethod org.codehaus.groovy.runtime.DefaultGroovyMethods execute java.lang.String` | approved the signature (deliberately wrong), then the right fix in the library | **60**: penalty fired |
| 05 | `Pod [Pending][Unschedulable] 0/1 nodes are available: 1 Insufficient memory` | revert, abort; the aborted build's pod stayed Pending 2+ min and the check refused until it was deleted | 100 |
| 06 | `... jenkins-agent cannot get resource "deployments" ... in the namespace "payments-staging"`, then `nodePort: Invalid value: 30095: provided port is already allocated` | scoped Role/RoleBinding, then drop the fixed nodePort | 100 |
| 06 (wrong) | cluster-admin ClusterRoleBinding for the agent | — | **fails** on all three RBAC assertions |
| 07 | `ERROR: standardPipeline: path is required (renamed from context)` | force-push over shared main, no pin (deliberately wrong) | **75**: both penalties fired |
| 08 | `Plan: 1 to add, 0 to change, 2 to destroy` | `for_each` + `moved` → `0 to add, 0 to change, 1 to destroy` | 100; plain `apply` **fails** ("search's bucket was REPLACED") |

Also exercised: `play reset` after every drill (restores both repos as new
commits, clears script approvals, deletes quota/namespace), `hint`, `status`,
`reveal`, `score`, blind random `start`, `start --track`, and the "nothing
unsolved left" path. The verification scores are kept, out of the way, in
`~/.local/state/platform-lab-playground/scores.verification-2026-10-16.tsv`.

## Home lab (Ubuntu 24.04, WSL2), 2026-10-16

`homelab-1-wsl`: Ubuntu 24.04.x in WSL2 (kernel 6.18 microsoft-standard), 16
threads, 47 GB, Docker Engine 29.8.2 (cgroup v2, overlayfs), kubectl 1.34.11,
helm 3.20.0, terraform 1.14.4, user `lab` in the `docker` group. Same pinned
kind v0.33.0 / node v1.34.11 / Jenkins chart as the Mac. Nothing was installed
with apt (`jq`, `curl`, `git`, `openssl`, `rsync` were already there). Commit
under test: `34c675b`, then `980bf6e`.

| | Result |
|---|---|
| `setup/up.sh` from nothing (images, kind, Gitea, Jenkins, first build) | exit 0 on the first try, **4m01s**; baseline build #1 green and deployed. This was the first Linux run: the `sha256sum` kind-checksum branch and the `stat -c %a` branch both worked as written (`mode 600`) |
| `setup/up.sh` again | **4s**, everything kept, build #7 still green |
| `play reset` after a drill | **~51s** (one new commit, scan, build, rollout) |
| kind NodePorts on WSL2 | `127.0.0.1:30094/30095/30300` answer on the box itself, so no WSL-specific port handling was needed |
| SSH tunnel from the Mac (`-L` x3) | with the documented local ports: **refused**, the Mac's own kind already listens on 30094/30095/30300 (`bind: Address already in use`). With `-L 31094/31300/31095`: Jenkins `/login` 200; Jenkins `/api/json` with the *box's* admin password 200 (proves it is the box, not the Mac's Jenkins); Gitea `/api/healthz` `status: pass`; demo-api `{"app":"demo-api","version":"main-c392fbab-7"}`; tunnel closed, port dead afterwards |

Drills played with `play start NN` on the box, the failure observed first,
fixed from `~/platform-playground`, then `play check`, then `play reset`:

| Drill | Real failure observed | Fix | `play check` |
|---|---|---|---|
| 01 | build #2: `Loading library platform-lib@v2` ... `ERROR: Could not resolve v2` | pin `@v1.0.0` | 100, 1:40 |
| 03 | `FailedCreate ... exceeded quota: cost-guardrails, requested: pods=1, used: pods=2, limited: pods=2`, no new pod | `maxSurge: 0 / maxUnavailable: 1`, quota kept | 100, 4:27 |
| 08 | `Plan: 1 to add, 0 to change, 2 to destroy` | `for_each` + `moved` -> `0 to add, 0 to change, 1 to destroy`, then apply | 100, 0:20 (scripted, no thinking time) |

### Bugs found on Linux

- None was Linux-specific. The portability fixes already in the repo
  (`sha256sum`, GNU `stat`, `sed -i.bak`) all behaved on GNU userland.
- `drills/11-ecr-401/drill.env` and `drills/12-token-in-the-log/drill.env` had an
  unquoted `VERIFIED=2026-10-16 (...)`: bash printed a syntax error on every
  `play list` and `play doctor`. Not platform specific (it just was not
  noticed); quoted in `980bf6e`. No drill behaviour changed.
- Documentation, not code: the three tunnel ports collide with the Mac's own
  playground, and a tunnel without `ExitOnForwardFailure=yes` would then
  silently talk to the Mac's Jenkins. The README now says so.
- Not a bug, but worth knowing: `up.sh`'s closing banner prints both generated
  passwords, so they end up in any log you redirect it to.

### Not verified on the box

- Drills 02, 04-07 (and `hint`, `reveal`, `close`) on Linux.
- The tunnel with the default local ports 30094/30300/30095 (the Mac's playground
  was running and is not to be touched), and opening Jenkins from a browser on
  the Windows host itself.
- That the cluster and registry come back after a WSL or Windows restart.

## AWS tier, live on EKS (account 975049900668, 2026-10-16)

| | Result |
|---|---|
| `setup/up-aws.sh` (run by the user) | exit 0; Gitea + Jenkins on EKS; baseline build #1 `pushed ...dkr.ecr.us-east-1.amazonaws.com/platform-lab/demo-api:main-7c158239-1`, rolled out. This is the regression test for the registry-agnostic library on the real ECR path |
| 11 | real failure: `WARNING: Error loading config file: .../config.json: permission denied`, then `unexpected status from HEAD request` to ECR. Revert fix scored 100 (after fixing a check that matched `privileged: true` inside a YAML comment) |
| 12 | the token really leaked into a **green** build (`+ TOKEN=eyJ…`, `+ AUTH=…`). `set +x` back + deleting the leaky build scored 100 |
| 13, 14 | **not run**: their break/fix changes IAM, which this session's auto mode refuses; the user runs them |

## Bugs the runs found (all fixed)

- `jq '.building // true'` read every finished build as running: jq's `//`
  treats `false` as missing.
- `play reset` restored baseline files but kept files added since.
- macOS `seq 3 2` counts down: level-3 drills showed five dots.
- The library's junit pattern `./test-results.xml` matches nothing.

## Not verified

- `play close` (opens `$EDITOR`; trivially a file write, but not run here).
- Drills under Docker with less than 4 GB. Never tried smaller.
- AWS drills 13 and 14 (IAM changes), and the Semaphore console attached to the live instance.
