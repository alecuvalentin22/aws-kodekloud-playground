# The platform layer, under GitOps

Until this directory existed, the repo had an honest split it was not honest
about: **workloads** were reconciled by Argo CD and Flux, and the **platform** —
ingress-nginx, Argo Rollouts, Flagger, sealed-secrets, Prometheus, APISIX — was
installed by `helm` from a shell script somebody ran by hand.

That is a very common shape and it fails the obvious question: *"you say GitOps.
What reconciles your platform?"* The truthful answer was "a bash script and my
memory of having run it."

A platform component is just an app with a Helm chart. It gets the same
treatment.

## One owner, not two

The demo workloads are deliberately reconciled by **both** controllers, into
`demo-argocd` and `demo-flux`, because that comparison is the point of the repo.

**The platform is owned by Argo CD alone**, and that is not laziness. Two
controllers reconciling one Helm release fight: each sees the other's changes as
drift and reverts them, forever, and the symptom is a release that flaps between
two revisions with both controllers reporting healthy. Pick one owner per
object. The comparison lives at the workload layer, where a conflict is
impossible because the namespaces are disjoint.

Flux's equivalent is written out in `flux/` for reading — it is what you would
use in a Flux-owned cluster — but it is not applied here.

## Sync waves, because order is real

`argocd.argoproj.io/sync-wave` on each Application:

| wave | what | why it cannot move |
|---|---|---|
| `-10` | storage (gp3 StorageClass) | APISIX's etcd needs a working provisioner before its PVCs will bind |
| `0` | ingress-nginx, Prometheus | Flagger's metrics come from nginx; APISIX's ServiceMonitor needs the operator's CRDs |
| `10` | APISIX gateway + etcd | needs storage |
| `20` | apisix-ingress-controller, Argo Rollouts, Flagger | the controller needs a gateway to push to |
| `30` | GatewayProxy + IngressClass, demo routes | needs the controller's CRDs to exist |

Waves matter here because two of these dependencies were discovered the hard
way this session: etcd `Pending` on a StorageClass that could not provision, and
a controller silently pushing nowhere because no `GatewayProxy` existed.

## Adopting what a script already installed

These charts are already installed as Helm releases from
`scripts/*-install.sh`. Handing them to Argo CD is an **adoption**, not a fresh
install, and adoption has a specific failure mode — Helm ownership metadata
(`meta.helm.sh/release-name`, `meta.helm.sh/release-namespace`,
`app.kubernetes.io/managed-by`) on objects Argo CD now also claims.

That is exactly T-21 in the backlog and it is worth reproducing deliberately
rather than tripping over. See `scenario 15`.

## What adoption actually looked like

Handing four script-installed Helm releases to Argo CD, measured:

| Application | outcome |
|---|---|
| `platform-storage` | Synced/Healthy |
| `platform-ingress-nginx` | Synced/Healthy |
| `platform-observability` | Synced/Healthy |
| `platform-apisix-wiring` | Synced/Healthy |
| `platform-apisix` | **OutOfSync**/Healthy |
| `platform-apisix-controller` | **OutOfSync**/Healthy |

Everything ended **Healthy**, and `helm list -A` still shows exactly one release
per chart — so the adoption worked; nothing was duplicated and nothing broke.
The gateway kept serving throughout.

### Finding 1 — `helm.releaseName` is the whole game

Argo CD names the Helm release after the **Application**. Without
`helm.releaseName`, `platform-apisix` rendered a brand-new release called
`platform-apisix` beside the script's `apisix` — two releases, one namespace.

The symptom is not a conflict, which is what makes it hard to read: the
Application sits `OutOfSync`/**`Missing`**, because from its point of view none
of its resources exist. Here it then wedged for seven minutes on the etcd
subchart's pre-upgrade hook, whose pod stayed `ContainerCreating` waiting on a
Secret belonging to a release that had never been installed.

### Finding 2 — adoption inherits every hand-patch as permanent drift

The two APISIX Applications remain `OutOfSync` and the reason is honest: the
install script *patched* things Helm does not know about — the gateway
NodePort, `topologySpreadConstraints`, `maxSurge: 0`, the ServiceMonitor's
`port`/`release` label, a generated Admin API key. Git does not express any of
it, so Argo CD correctly reports a difference forever.

**That is the real lesson of adopting a script-managed release: git has to
express everything the script did, or you trade "a script nobody remembers
running" for "a permanent diff nobody can action".** The second is better —
it is at least visible — but it is not done.

Closing it means moving those patches into the `valuesObject`, or into a
kustomize overlay, and deleting them from the script. That is the remaining
work, and it is deliberately not hidden behind an `ignoreDifferences` blanket.

### Finding 3 — one owner per object, one layer down

The controller chart ships an `IngressClass` with empty `.spec.parameters`;
`platform-apisix-wiring` owns the real one carrying the `GatewayProxy`
reference. Both Applications claimed it, and with `selfHeal` on they would take
turns reverting each other — the gateway silently losing its routing every time
the chart's version won. The controller Application now yields it via
`ignoreDifferences`.

Exactly the same rule as Argo CD vs Flux at the top of this file, and it applies
between two Argo CD Applications just as much as between two controllers.
