# Two GitOps controllers, one repository, one cluster

Argo CD and Flux both reconcile **this repository** into **the same EKS
cluster**, into two namespaces:

| Controller | Namespace | Reconciles |
|---|---|---|
| Argo CD `v3.5.x` | `demo-argocd` | `gitops/app/overlays/argocd` |
| Flux `v2.9.x` | `demo-flux` | `gitops/app/overlays/flux` |

The two overlays share a single kustomize base and differ only in namespace and
a banner string. That is deliberate: **anything you observe between them is a
property of the controller, not of the manifests.**

---

## The demo worth running

Scale both deployments by hand and watch what happens.

```bash
kubectl -n demo-argocd scale deploy/podinfo --replicas=5
kubectl -n demo-flux   scale deploy/podinfo --replicas=5
watch kubectl get deploy -A -l app.kubernetes.io/name=podinfo
```

Argo CD reverts within seconds — `selfHeal: true` means the cluster is not
allowed to disagree with Git. Flux reverts on its next reconcile interval
(`interval: 10m` here, so up to ten minutes) unless you hurry it along:

```bash
flux reconcile kustomization apps --with-source
```

Neither is "better". They encode different assumptions about how quickly the
cluster should be forced back into line, and how surprising that should be to a
human holding a terminal.

### Measured, on this cluster

```
                 argocd   flux
baseline              1      1
scaled to 5 by hand   5      5
t+10s                 1      5     <- Argo CD already reverted
t+90s                 1      5     <- Flux still drifted, interval not elapsed

flux reconcile kustomization apps --with-source
after                 1      1
```

Argo CD reverted in under ten seconds without being asked. Flux held the drift
for as long as its `interval` said it would, then reverted the moment it was
told to look. Same repository, same cluster, same base manifests -- the only
variable is the controller.

### The result that inverts it

Same cluster, a git push instead of a manual change -- how long until it is live?

```
git push -> live       flux  78s     argo cd  155s
manual drift -> fixed  flux  up to 10m   argo cd  <10s
```

**Each wins one, and it is the same mechanism seen from two sides.** Flux polls
the SOURCE every `interval` (1m here), so it hears about a commit sooner. Argo CD
watches the CLUSTER continuously via `selfHeal`, so it notices a manual change
almost instantly, but only polls git every ~3 minutes by default.

Neither number is a property of the tool. Both are configuration:

- Argo CD closes the git gap with a **webhook** (`/api/webhook`), which takes
  the 155s to roughly the round-trip time. Without one you are polling.
- Flux closes the drift gap by lowering `interval`, at the cost of more API and
  git traffic, or with `flux reconcile` on demand.

The honest summary is that **Flux defaults favour source-of-truth freshness and
Argo CD defaults favour cluster convergence** -- and if you care about both, you
configure both, in opposite directions.

Which behaviour you want is a real decision, not a detail. `selfHeal` means an
engineer's emergency `kubectl edit` is undone within seconds, possibly mid
incident; Flux's interval means the cluster can sit knowingly wrong for minutes.
Argo CD's answer is to disable auto-sync as a break-glass procedure; Flux's is
`flux suspend`.

---

## Where the two genuinely differ

| | Argo CD | Flux |
|---|---|---|
| Unit of work | `Application` — source **and** destination in one object | `GitRepository` + `Kustomization` — source and intent are separate |
| Reuse | one Application per source/destination pair | ten Kustomizations can share one clone |
| Ordering | `sync-wave` annotations, **within** an Application | `dependsOn` **between** Kustomizations, with `wait: true` |
| Namespace creation | `CreateNamespace=true` sync option | declare the `Namespace` object like anything else |
| Pruning default | opt in via `automated.prune` | opt in via `prune: true` |
| Drift correction | `selfHeal`, near-immediate | next `interval`, or `flux reconcile` |
| Interface | web UI in the box | web UI via the **Flux Operator** (AGPL-3.0, by Flux core maintainers) — `port-forward svc/flux-operator 9080` |
| Multi-cluster | one control plane reaches out to registered clusters | one Flux per cluster, each pulling for itself |

That last row is the deepest split. **Argo CD is a hub** — one installation
managing many clusters, with a single pane of glass and a single blast radius.
**Flux is an agent** — every cluster runs its own copy and pulls for itself,
with no central thing to lose. Multi-tenancy in Argo CD is `AppProject` plus
RBAC; in Flux it is namespaces plus `serviceAccountName` on each Kustomization.

---

## What makes this configuration production-grade rather than a demo

**Argo CD**
- `AppProject` restricts destinations to exactly `demo-argocd`, and
  `clusterResourceWhitelist: []` denies every cluster-scoped resource. The
  documented trap is a project whose destinations include the `argocd`
  namespace — that is effectively cluster admin, because an Application can then
  rewrite Argo CD's own RBAC.
- `ServerSideApply=true`, required for objects that exceed the 262144-byte
  client-side apply annotation, and what makes per-field ownership meaningful.
- `retry` with exponential backoff, so a transient webhook failure does not wait
  for the next reconcile loop.
- `PruneLast=true`, so a rename cannot delete the replacement.
- Root Application manages the directory that contains itself, so adding an
  `ApplicationSet` is a commit rather than a `kubectl apply`.

**Flux**
- `dependsOn` plus `wait: true` — apps do not start reconciling until
  infrastructure is genuinely `Healthy`, not merely applied.
- `healthChecks` naming the specific Deployment, so "did it apply" and "does it
  work" are different questions.
- `retryInterval` and `timeout` set explicitly rather than inherited.
- One `GitRepository` shared by both Kustomizations — clone once, use twice.

**Both**
- Resource requests on every container. On Fargate these are not advisory: the
  micro-VM is sized from the sum of container requests, so omitting them buys
  the 0.25 vCPU / 0.5 GB minimum whatever the workload actually needs.

---

## What is deliberately NOT here

**Secrets.** Neither controller is wired to a secret store. The Argo CD docs are
unambiguous that secrets should be materialised by a controller **on the
destination cluster** — External Secrets Operator, Sealed Secrets, or SOPS —
rather than decrypted during manifest generation. For a public repository,
Sealed Secrets or SOPS+age are the safe options because the committed ciphertext
is useless without the in-cluster key. Adding one is the obvious next step; the
wrong move would be committing anything that a reader of this repo could decrypt.

**Image automation.** Flux's `ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation`
would let a new image tag write itself back to Git. It needs write credentials
to this repository, which is a bigger decision than it looks on a public repo.

**Multi-cluster.** Both are pointed at one cluster. Argo CD would grow by adding
labelled cluster `Secret`s and a cluster generator; Flux would grow by
installing Flux on the second cluster and giving it its own `clusters/` directory.
