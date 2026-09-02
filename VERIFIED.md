# What is verified live, and what is not

Written at the end of the 2026-08-20 session, when the playground expired. The
distinction matters: this repo's whole claim is that its numbers come from
running things, so anything that has *not* been run should say so rather than
sit in the same tone as everything that has.

## Verified against a live EKS v1.33 cluster (account 637423470040)

| | Evidence |
|---|---|
| Three-phase pod-density fix | 110 allocatable pods/node, 58 pods running, 0 Pending |
| Argo CD + Flux reconciling one repo | 3 Applications Synced/Healthy, 2 Kustomizations Ready |
| Scenario 06 — Rollouts rollback | broken image aborted at 100s; slow release aborted at 50s, "canary within 1s: 0/30" |
| Scenario 07 — Flagger | Succeeded in 150s; Failed and rolled back at 90s |
| Scenario 08 — A/B | 20/0 in all four directions at weight 0 |
| Scenario 09 — sealed secrets | unsealed in `demo-secrets`, refused in `demo-secrets-evil` |
| Scenario 10 — Helm | Flux 1 release Secret / Argo CD 0; drift 10s vs never vs ~20s |
| Scenario 11 — webhook | signed payload → HTTP 200 → both Applications refreshed |
| Scenario 12 — Flux Operator | FluxInstance Ready in 12s; UI HTTP 200 on :9080 |
| NodePorts public via Terraform | 7 rules applied; 200 from all three node IPs |

## Re-verified 2026-08-21 on a second playground (account 471112703240)

Everything below was re-run from scratch on a brand-new account, which is what
"reproducible" has to mean:

| | Result |
|---|---|
| `./scripts/eks-up.sh` end to end | exit 0, all three phases, **110 max-pods on all 3 nodes in one run** |
| `~/.kube/config` left alone | **identical checksum before and after**, 0 lab contexts added |
| `make kubeconfig` | writes the dedicated file, prints MAXPODS 110 |
| `scripts/scenario` with no `KUBECONFIG` exported | finds the cluster |
| `gitops-install.sh` + `gitops-addons.sh` | exit 0, 32 pods running, 0 pending |
| Scenario 06, run **twice back to back** | identical both times, both parts roll back |
| Scenario 10 `--only argocd` | `helm list` empty, 0 release Secrets, drift corrected in 10s |
| NodePorts opened by Terraform, no manual step | 7 rules present after `eks-up.sh`; 30081/30082/30084/30090 all 200 |
| Argo CD webhook | signed payload → HTTP 200 → both Applications refreshed |
| A/B routing | no header → A, `X-Cohort: beta` → B, cookie → B |
| Flux Operator UI on :30086 | 200 from all three nodes, `<title>Flux Status</title>` |

A fifth bug: the NodePort **firewall** rules were open but `argocd-server` ships
as `ClusterIP`, so :30084 answered `000` while the security group was wide open.
Exposing the UI is now part of `gitops-install.sh` rather than a side effect of
running the webhook script.

Four bugs surfaced and were fixed in the process — see the git log for
2026-08-21. The two that mattered: `eks-up.sh` would have written into
`~/.kube/config`, and `kubectl apply -f gitops/progressive/rollouts-nginx/`
applied files alphabetically, so the `AnalysisTemplate` preceded its Namespace
and the Rollout came up `Degraded` referencing a template that was never
created. Both only fail on a clean cluster, which is precisely where a
reproducibility claim gets tested.

## APISIX + observability, 2026-09-01 (account 471112918502)

| | Result |
|---|---|
| `eks-up.sh` preflight | caught the rotated IP and refused in ~5s |
| 4 nodes, 110 max-pods | one script run |
| `make observability` | Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics |
| `make apisix` | gateway 3/3 across 3 distinct nodes, etcd 3/3, controller + ADC |
| demo route through the gateway | `curl -H 'Host: demo.apisix.local'` → `v1` |
| Scenario 13 | hop A silent for 90s, converged 53s; hop B loud, traffic unaffected |
| Scenario 14 | 183/17 split, 40/40 header, 98.3% vs 76.6% blind-spot contrast |

**Not run this session:** T-22 (JWT/OIDC at the gateway), T-25 (rate limiting
across replicas), T-26 (etcd ops), T-27 (standalone mode), T-28 (the Kong vs
APISIX table). Scenario 13's `scenario_reset` and scenario 14's have both been
exercised, but neither scenario has been run twice back-to-back the way
scenario 06 was, so their idempotence is unproven.

**Also unverified:** the HA claims in `kubernetes/apisix/ha.yaml`. The PDB and
the 3-node spread are applied and visible, but no `kubectl drain` has been run
against them, so "a drain does not drop traffic" is currently a design intent
rather than a measurement. T-20's acceptance criteria asks for that explicitly.

## Best practices + version audit, 2026-09-02 (account 587263142585)

**Verified on a live cluster:**

| | Result |
|---|---|
| `versions.env` + `check-versions.sh` | 12/12 components current, exit 0 |
| Argo CD running the pinned version | `quay.io/argoproj/argocd:v3.5.2` |
| `eks-up.sh` phase 4 | `gp3 (ebs.csi.aws.com)` default automatically, no manual step |
| `ServerSideDiff=true` | **`platform-apisix` went Synced** — it was permanently OutOfSync before |
| `FailOnSharedResource=true` + chart-owned IngressClass | **`SharedResourceWarning` count: 0** |
| Chart-rendered wiring | `IngressClass → GatewayProxy/apisix-ingress-controller-config`, no hand-written pair |
| External etcd | `bitnamilegacy/etcd:3.6.4-debian-12-r4` — **pinned**, replacing the bundled `:latest` |
| End to end | ApisixRoute `Accepted`, gateway serves `v1` |
| Final | 9/10 Applications Synced, **10/10 Healthy**, 54 pods, 0 Pending |

**Two things NOT fixed, stated plainly rather than rounded up:**

1. **The gateway runs APISIX's published default admin key.**
   `apisix.admin.credentials.secretName` is in the chart's values schema and does
   **not work** in chart 2.17.0 — the rendered ConfigMap still contains the
   literal `edd1c9f0…`. To get the route serving, `secret/apisix-admin` was
   aligned *down* to that default so the controller and gateway agree. That is a
   **security regression** against the generated key, taken knowingly on a
   throwaway cluster whose Admin API is ClusterIP-only. Do not copy it.

2. **The gateway NodePort cannot be pinned from git.** The chart has no
   `service.http.nodePort` value, so it is assigned at random and the Terraform
   rule for 30093 points at nothing. The imperative installer patches it; the
   Application cannot.

Both are the same shape as the drift documented below: the imperative script can
patch things the Helm chart does not expose, and an Application cannot.

**`platform-etcd` stays OutOfSync** on `StatefulSet/apisix-etcd` while sync
reports "successfully synced (all tasks run)" — the same defaulted-field pattern
as before, now on the image override.

## Platform under GitOps, 2026-09-01

The repo previously reconciled its workloads with Argo CD and Flux and installed
its platform with a shell script. `gitops/platform/` closes that.

| | Result |
|---|---|
| app-of-apps applied, 6 child Applications generated | yes |
| Helm releases after adoption | **one per chart** — nothing duplicated |
| gateway serving throughout | yes, `v1` on :30093 the whole time |
| `platform-storage` / `-ingress-nginx` / `-observability` / `-apisix-wiring` | Synced/Healthy |
| `platform-apisix` / `-apisix-controller` | **OutOfSync**/Healthy |

**Known and deliberate:** the two APISIX Applications stay `OutOfSync` because
the install script patched things Helm does not know about — NodePort,
`topologySpreadConstraints`, `maxSurge: 0`, the ServiceMonitor's port and
release label, a generated admin key. Git expresses none of it. Moving those
into `valuesObject` is the remaining work; it is not hidden behind a blanket
`ignoreDifferences`, so the diff stays visible and actionable.

**Researched, and two of my explanations were wrong** — see
`gitops/platform/README.md`. Argo CD never installs a Helm release (it runs
`helm template`), so "adoption" and "a second release" were both incorrect
framings; and most of the `platform-apisix` diff is server-side defaulting,
likely triggered by `ServerSideApply=true` auto-enabling a diff strategy the
docs mark **discontinued**. Untested hypothesis: add `ServerSideDiff=true`.

**Open, and it fired.** Two Applications claimed `IngressClass/apisix`. Once
`platform-apisix-controller` reached `Synced` it won, and
`.spec.parameters` — the GatewayProxy reference the controller needs — went
**empty**. Traffic kept flowing the whole time, because APISIX serves from etcd
and does not need the controller to do so, so every signal stayed green while
the ability to apply the *next* change was gone. Restored by hand; the
controller's `selfHeal` is off for that object as a stopgap. The two real fixes,
and their costs, are in `gitops/platform/README.md`. This is not resolved.

**Not verified:** Flux's equivalent of the platform layer is described in
`gitops/platform/README.md` but not written or applied — the platform is
Argo-CD-owned on purpose. And no `kubectl drain` has been run, so the HA claim
in `kubernetes/apisix/ha.yaml` remains design intent.

## Previously NOT run end to end (now all run)

**`scripts/eks-up.sh`.** Its three phases were executed by hand — `terraform
apply` with the ASG at zero, `kubectl set env` on the daemonset, `terraform
apply` to scale up — and the script was written around them afterwards. It has
never been invoked as a script. Two bugs were found by reading it after the
cluster was gone, and both are fixed but unproven:

- it called `aws eks update-kubeconfig` with **no `KUBECONFIG` exported**, so it
  would have written a lab context into `~/.kube/config`, next to production
  ones — the exact mistake this repo says it will not make
- it called `rollout status daemonset/aws-node` immediately after cluster
  creation. EKS installs vpc-cni shortly *after* `CreateCluster` returns, and
  `rollout status` does not wait for a missing object — it exits with "not
  found", which under `set -e` kills the build at the one step that cannot be
  redone later

**`./scripts/scenario run 06`** and **`run 10 --only argocd`** with their final
versions. Both were rewritten after their last full run; the individual
measurements above were taken by hand or from the Flux side. The logic is the
same, but the wrappers have not been executed as written.

**The kubeconfig unification** (`CLUSTER` → `KUBECONFIG`) was made after the
cluster expired. Scripts parse and `make help` prints the right path, but no
command has run against a cluster with it.

## First thing to do on the next playground

```bash
./scripts/eks-up.sh            # this is the test
make kubeconfig                # MAXPODS must read 110, not 17
./scripts/scenario run 06 --only argocd
./scripts/scenario run 10 --only argocd
```

If those four pass, everything in this repo has been run as written.

Also expect: **the committed `SealedSecret` will not decrypt.** A fresh cluster
generates a new sealing key. `make secrets` re-seals. That is documented
behaviour, not a regression.
