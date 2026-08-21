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
