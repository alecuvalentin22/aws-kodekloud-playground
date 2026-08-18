# Scenarios — reproducible GitOps experiments

A working demo shows the happy path. These show what each controller does when
something is **wrong**, which is where Argo CD and Flux actually differ.

```bash
./scripts/scenario list
./scripts/scenario run 03                 # both controllers
./scripts/scenario run 03 --only flux     # one
./scripts/scenario reset 03
./scripts/scenario status
```

Every scenario runs the **same break against both controllers** on the same
cluster, and prints timestamped observations rather than conclusions.

| | Question | Measured |
|---|---|---|
| **01** | If a namespace is deleted out from under it, what happens? | **argocd recovered in 24s · flux still gone at 120s, reporting `ready=True`** |
| **02** | What does each report while a pod cannot schedule? | **argocd never broke (selfHeal) · flux `pending=1` for 84s, reporting `ReconciliationSucceeded`** |
| **03** | How fast is manual drift undone? | **argocd ~10s · flux still drifted at 80s** |
| **04** | How long from `git push` to live? | **flux 78s · argocd 155s** — inverts 03 |

## The finding that runs through 01 and 02

Both scenarios were written expecting an ordering story. What they actually
exposed is a **status semantics** difference, and it is the sharpest thing in
this repo.

**Scenario 01** — delete the namespace, leave git untouched:

```
argocd  t+12s  OutOfSync/Missing   pods=0
        t+24s  Synced/Progressing  pods=3     <- recovered, and SAID so
flux    t+12s  ready=True          pods=0
        ...
        t+120s ready=True          pods=0     <- gone, and still says ready
```

**Scenario 02** — make a pod unschedulable:

```
argocd  pending=0 throughout          selfHeal reverted it before it could break
flux    pending=1 for 84 seconds      status: ReconciliationSucceeded
```

**Argo CD's status answers "does the cluster match git, and is it healthy?"
Flux's answers "did my last apply succeed?"** Those are different questions, and
for 84–120 seconds Flux's answer was `True` while the workload was degraded or
absent.

This is not a bug and Flux is not wrong -- it is reporting exactly what it
measured, at the last tick. But if you page on `Kustomization.ready`, you will
not be paged. Flux's answer to this is `healthChecks` on the Kustomization
(configured in this repo) and `wait: true`, which gate readiness *during* a
reconcile -- they do not make it a continuous health watch between reconciles.

The operational consequence: **with Flux, alert on the workload, not on the
controller.** With Argo CD you can alert on the Application, because it tracks
live state continuously.

## Why 03 and 04 together are the interesting result

Each tool wins one, for the same underlying reason:

- **Argo CD** watches the *cluster* continuously (`selfHeal`) → fast drift
  correction, but polls git every ~3 min → slower to see a commit.
- **Flux** polls the *source* every `interval` (1m here) → fast to see a commit,
  but only notices drift on that same tick.

Neither number is a property of the tool. A webhook takes Argo CD's 155s to
roughly a round trip; a lower `interval` takes Flux's drift window down at the
cost of git and API traffic. **The defaults optimise for different things** —
Flux for source freshness, Argo CD for cluster convergence.

## Writing a new scenario

Create `gitops/scenarios/NN-name/run.sh` defining three functions. The runner
supplies `$CTL` (`argocd`/`flux`), `$NS` (`demo-argocd`/`demo-flux`) and `$ROOT`:

```bash
# QUESTION: one line, shown by `scenario list`
# EXPECT:   what you predict, so the run can contradict you

scenario_apply()   { : "break something for $CTL"; }
scenario_observe() { : "poll and print timestamped facts"; }
scenario_reset()   { : "return to baseline"; }
```

Two rules that keep these honest:

1. **Print observations, not verdicts.** The value is in seeing the numbers, and
   in being able to be surprised. Scenario 04 was written expecting Argo CD to
   win and it lost.
2. **Never suppress the output of the thing you are testing.** Scenario 02's
   first version patched memory to `900Gi`, which the API server rejects because
   requests may not exceed limits -- and it hid stderr. So nothing broke, and the
   scenario confidently reported "Healthy" on both controllers for 96 seconds. A
   convincing non-result is worse than a failure.
3. **Never rewrite git history.** Scenario 04 is deliberately read-only for this
   reason — it reports the configured intervals rather than pushing a commit. A
   test harness that force-pushes to `main` is a worse problem than the thing it
   measures.

---

## 05 — a broken release, and what GitOps does NOT do

The most common misconception about GitOps, corrected by measurement.
**Reconciliation guarantees the cluster matches git. It says nothing about
whether what is in git works.**

Broken image tag pushed to `main`:

```
argocd  serving=3  broken=1  for 105s   health: Progressing -> Degraded
flux    serving=3  broken=1  for 105s   ReconciliationSucceeded
git revert + reconcile      -> both recovered in 26s
```

Both deployed the broken release faithfully. Neither rolled back. `selfHeal`
makes it *worse* — it will keep re-applying the broken manifest.

**What saved the service was Kubernetes, not the GitOps controller.** A
Deployment's `RollingUpdate` will not scale down healthy old pods until new ones
are Ready, so `serving=3` held throughout while the new ReplicaSet hung. That
`maxUnavailable` behaviour is the entire free safety net.

**Introduce the break through git, not kubectl.** The first version of this
scenario used `kubectl set image`; Argo CD's selfHeal reverted it in 12s, so it
measured selfHeal rather than a bad release, and made Flux look worse for no
reason. Two very different findings that look identical if you are careless
about how the break arrives.

## Progressive delivery — what neither tool does natively

Canary, blue/green and A/B are **not** features of Argo CD or Flux. Both stop at
"apply the manifests". What you get is a `RollingUpdate`: no traffic weighting,
no metric gates, no automatic rollback. Scenario 05 is what that looks like when
a release is bad.

Each ecosystem has a separate controller for it:

| | Argo CD | Flux |
|---|---|---|
| Add-on | **Argo Rollouts** | **Flagger** |
| Model | replaces `Deployment` with a `Rollout` CRD; explicit `steps` (`setWeight`, `pause`) | keeps your `Deployment`, generates the canary machinery around it |
| Gate | `AnalysisTemplate`, optional | metric queries, central to the design |
| Rollback | automatic on failed analysis | automatic on failed analysis |
| Traffic splitting | needs a provider: Gateway API, Istio, NGINX, ALB | same requirement |

Both need something that can **weight traffic**. Without a mesh or a capable
ingress you get replica-count approximation, not a real canary — and A/B
specifically needs header or cookie routing, so it has the same dependency.

Not built here: it is a 45–60 minute setup on its own, and it is where the two
ecosystems genuinely diverge rather than doing the same thing at different
speeds. Worth a dedicated session.
