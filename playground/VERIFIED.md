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

## Bugs the runs found (all fixed)

- `jq '.building // true'` read every finished build as running: jq's `//`
  treats `false` as missing.
- `play reset` restored baseline files but kept files added since.
- macOS `seq 3 2` counts down: level-3 drills showed five dots.
- The library's junit pattern `./test-results.xml` matches nothing.

## Not verified

- `play close` (opens `$EDITOR`; trivially a file write, but not run here).
- Drills under Docker with less than 4 GB. Never tried smaller.
- The AWS tier and the Semaphore console: see their own READMEs once they land.
