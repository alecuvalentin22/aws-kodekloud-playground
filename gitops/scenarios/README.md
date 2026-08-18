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
| **01** | If a dependency breaks, is the dependent still deployed? | Flux `dependsOn` + `wait` blocks it; Argo CD has no boundary without sync-waves |
| **02** | Where does a rejected manifest surface? | Argo CD: Application health. Flux: Kustomization conditions |
| **03** | How fast is manual drift undone? | **argocd ~10s · flux still drifted at 80s** |
| **04** | How long from `git push` to live? | **flux 78s · argocd 155s** — inverts 03 |

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
2. **Never rewrite git history.** Scenario 04 is deliberately read-only for this
   reason — it reports the configured intervals rather than pushing a commit. A
   test harness that force-pushes to `main` is a worse problem than the thing it
   measures.
