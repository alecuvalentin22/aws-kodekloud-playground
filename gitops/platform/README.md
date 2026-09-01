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

## "Adoption" is the wrong word, and the difference matters

These charts were installed as Helm releases by `scripts/*-install.sh`. Pointing
an Argo CD Application at the same chart does **not** adopt that release —
Argo CD never reads it. It simply starts managing the same *objects*, and the
Helm release Secret sits there, ignored.

That leftover Secret is a **latent hazard rather than a conflict**: nothing
fights today, but anyone running `helm upgrade apisix` later becomes a second
writer over objects Argo CD believes it owns. The community remedy is to remove
the release metadata once Argo CD is managing the objects (`helm uninstall
--keep-resources`, or deleting the release Secret). That is engineering-blog
practice, **not** Argo CD documentation — Argo CD has no official
"adopt an existing release" procedure, because from its side there is nothing
to adopt.

The honest fix for this repo is upstream of all that: the install scripts and
the Applications should not both configure the same charts. One of them has to
go. See `scenario 15`.

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

### Finding 1 — `helm.releaseName`, and a correction to how it works

**Corrected after checking the docs.** My first explanation said Argo CD
installed "a second Helm release". That is wrong: Argo CD never runs
`helm install`. The FAQ is explicit that it uses Helm *"only as a template
mechanism"* — `helm template`, then apply. It never creates or reads a Helm
release Secret, so `helm list` could never have shown a second one.

What `helm.releaseName` actually does is set `.Release.Name` as a **template
variable**, defaulting to the Application name. This chart builds resource
**names** from it. So without the line, `platform-apisix` rendered a parallel
set of objects called `platform-apisix-*` alongside the script's `apisix-*` —
**duplicate objects, not duplicate releases**.

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

## Two errors this surfaced, one fixed and one open

### Fixed — an enumerated whitelist has to be kept up to date

The controller Application's sync **failed outright**, five retries, while the
Application still read `Healthy`:

```
one or more synchronization tasks are not valid:
resource admissionregistration.k8s.io:ValidatingAdmissionPolicy
is not permitted in project platform (retried 5 times)
```

`ValidatingAdmissionPolicy` and `ValidatingAdmissionPolicyBinding` are the
CEL-based admission kinds (GA in 1.30) and are **different kinds** from the
`ValidatingWebhookConfiguration` already on the list — enumerating the webhook
did not cover them. apisix-ingress-controller 2.x ships them to guard Gateway
API upgrades.

Two things worth taking from it. `Healthy` means *"what exists is working"*, not
*"what git asked for exists"* — the app was Healthy through five failed syncs.
And this is the price of an enumerated `clusterResourceWhitelist` over `'*'`: a
chart that starts shipping a new cluster-scoped kind **stops** and names it,
instead of silently acquiring it. That is the right trade, but it is a trade.

### Open — `SharedResourceWarning` on the IngressClass

```
SharedResourceWarning: IngressClass/apisix is part of applications
argocd/platform-apisix-controller and platform-apisix-wiring
```

`ignoreDifferences` does **not** fix this. It suppresses the diff and leaves
ownership shared, so the warning stands. Nothing is currently broken — the
gateway routes correctly and `parameters` survives — but two Applications
claiming one object is precisely the condition this README opens by warning
against, and it should not be left.

The chart templates its IngressClass unconditionally; there is no `create`
toggle. So there are exactly two honest options:

1. **`gatewayProxy.createDefault: true`.** The chart then creates both the
   GatewayProxy and an IngressClass already wired to it — one owner, no
   warning, no hand-written wiring. The cost is that the chart inlines the
   admin key as a literal:

   ```yaml
   adminKey: {value: edd1c9f034335f136f87ad84b625c8f1, type: AdminKey}
   ```

   which is APISIX's published default, in git. Setting a real key there is
   worse. This only works if the chart grows support for a `secretKeyRef`.

2. **Keep the hand-written GatewayProxy** (which reads the key from a Secret)
   and stop `platform-apisix-wiring` from managing the IngressClass, letting the
   controller Application own it — then find another way to set `parameters`,
   because the chart does not expose them.

Option 1 is cleaner and less secure; option 2 is more secure and needs a
mechanism that does not exist yet.

### And then the conflict actually fired

Leaving it "not currently broken" did not last. Once the controller Application
reached `Synced`, **it won**:

```
$ kubectl get ingressclass apisix -o jsonpath='{.spec.parameters}'
        <empty>
```

The chart's parameter-less IngressClass overwrote the wiring. And here is the
part worth the whole exercise — **traffic kept flowing the entire time**:

```
routing: v1  v1  v1
```

APISIX had the routes in etcd already, and serving them does not require the
controller. So every signal was green: Application `Synced`, Application
`Healthy`, gateway answering correctly, no error anywhere. The only thing that
had actually broken was the ability to apply the **next** change — the exact
failure shape scenario 13 measures deliberately, arrived at here by accident.

That is why `ignoreDifferences` was never sufficient: it silences the report
while leaving both Applications able to write. The controller's `selfHeal` is
now off for this object so it cannot win again, which is a stopgap, not the
fix. The fix is still one of the two options above.

**Do not read "Synced/Healthy" as "the platform works."** It meant, here,
"the wiring is gone and nobody noticed."”

## Researched afterwards: is permanent `OutOfSync` normal?

Short answer: **documented as possible, never as acceptable.** Argo CD has a FAQ
entry titled *"Why is my application still OutOfSync immediately after a
successful Sync?"*, and the
[Diffing Customization](https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/)
page states verbatim: *"It is possible for an application to be OutOfSync even
immediately after a successful Sync operation."*

But it lists **enumerated causes, each with a required remedy** — controllers or
mutating webhooks altering objects, fields the API server drops, `Prune=false`
with resources pending deletion, non-deterministic Helm functions, HPA metric
reordering, `status` committed to git. There is no blanket "some drift is fine";
maintainers triage unmatched instances as bugs
([#14666](https://github.com/argoproj/argo-cd/issues/14666),
[#14591](https://github.com/argoproj/argo-cd/issues/14591)).

### The cause that probably applies here

`ServerSideApply=true` — which every Application in this directory sets —
**auto-enables the Structured-Merge Diff strategy**, and the
[Diff Strategies](https://argo-cd.readthedocs.io/en/stable/user-guide/diff-strategies/)
doc marks it:

> **Feature Discontinued** — […] challenges using this strategy to calculate
> diffs for CRDs **that define default values**.

Measured on the live cluster, `platform-apisix`'s etcd StatefulSet differed in
**16 fields, 15 of which were server-side defaults** the chart never sets
(`dnsPolicy`, `restartPolicy`, `schedulerName`,
`terminationGracePeriodSeconds`, `revisionHistoryLimit`, `volumeMode`,
`persistentVolumeClaimRetentionPolicy`, …). That is exactly the failure class
the doc describes.

So most of the noise is likely **self-inflicted by a sync option added for an
unrelated reason** (CRDs exceeding the client-side apply size limit). The
documented replacement is `ServerSideDiff=true` (stable since v3.1.0) — which
has its own open bugs, so it is a hypothesis to test, not a certain fix.

**The one genuine difference** was a Helm-computed `checksum/token-secret` pod
annotation, differing because the etcd token Secret is not byte-identical
between the script's install and Argo CD's render. One real diff is enough to
mark the whole resource `OutOfSync`.

### On the shared IngressClass — confirmed, and a mechanism I missed

- `ignoreDifferences` **does not** resolve ownership. Confirmed by the docs:
  *"Argo CD uses the ignoreDifferences config just for computing the diff […]
  during the sync stage, the desired state is applied as-is."* Suppressing the
  report while both Applications keep writing is exactly what let the
  IngressClass get blanked.
- **`FailOnSharedResource=true`** is the documented sync option for this, and
  this repo was not using it. It is a **circuit-breaker, not a resolution** — it
  makes the sync *fail* instead of silently clobbering. Given that the silent
  clobber here cost a working gateway control plane, failing loudly is the
  better default.
- There is **no Application-level "exclude one resource" field**. So the plan of
  "just exclude the IngressClass from the chart Application" is not natively
  possible. The real options are kustomize `helmCharts` inflation with a
  `$patch: delete`, a Helm post-renderer, or vendoring the chart — all community
  patterns, none documented by Argo CD.
- "One owner per object" is **not** stated as official Argo CD doctrine. It is
  implied by resource tracking and by maintainer comments (*"the last
  application to sync the resource wins"*), but it is community best practice
  rather than documented policy. Worth saying accurately.

### Also worth knowing about Helm hooks here

Argo CD maps `pre-install`/`pre-upgrade` both to `PreSync`, and **cannot tell an
install from an upgrade — every operation is a sync**, so both fire every time.
ingress-nginx's `admission-create` hook hanging is a *documented* failure with an
official workaround (`argocd.argoproj.io/hook: Skip`). This repo dodged it by
disabling admission webhooks for unrelated capacity reasons; that was luck, not
design.
