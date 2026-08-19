# Progressive delivery — what the GitOps controllers do NOT do

Argo CD and Flux both stop at "apply the manifests". Neither does canary,
blue/green or A/B: what you get is a Kubernetes `RollingUpdate`, which has no
traffic weighting, no metric gates and no automatic rollback. Scenario 05 shows
exactly what that costs when a release is bad.

Each ecosystem has a **separate controller** for this:

| | Argo Rollouts | Flagger |
|---|---|---|
| Pairs with | Argo CD | Flux (works with either) |
| Model | **replaces** `Deployment` with a `Rollout` CRD | **keeps** your `Deployment`, generates the canary around it |
| Drives from | explicit `steps` (`setWeight`, `pause`) | metric analysis, on an interval |
| Gate | `AnalysisTemplate`, optional | metric queries, central to the design |
| Rollback | automatic when analysis fails | automatic when analysis fails |
| Without a mesh | replica-count approximation | needs a provider; `kubernetes` provider does blue/green only |
| Maturity (Aug 2026) | v1.9.1, ~4 releases in 20 months, pushed daily | v1.44.0, 8 years old, ~6 releases in 20 months, still `v1beta1` API |

**Both need something that can weight traffic** for a true canary — Gateway API,
Istio, Linkerd, NGINX or an ALB. Without one you are splitting by replica count,
which approximates a canary but cannot do 5% or header-based A/B.

That last point is the honest headline: **"we do canary deployments" is a
statement about your traffic layer as much as your GitOps tool.**

---

## Measured on EKS v1.33 (3 × t3.medium self-managed nodes)

### Argo Rollouts — canary works, and the analysis distinction is the point

A good release, `6.7.1 -> 6.7.0`, steps `25 / 50 / 75` with 30s pauses:

```
t+15s   Progressing  step=1  new=1 old=3     25%
t+45s   Progressing  step=2  new=2 old=2     50%
t+75s   Paused       step=4  new=3 old=2     75%
t+120s  Healthy      step=6  new=4 old=0     promoted
```

A **broken** image through the same canary:

```
t+120s  Progressing  step=0  serving=3 broken=1
        message: "more replicas need to be updated"
```

**It capped the blast radius at 25% and stopped — but did not roll back.**
Steps *pause*; they do not *judge*. That is the single most useful thing to know
about Argo Rollouts: a canary without analysis is a containment mechanism, not
an automatic one. Recovery is still a human.

### The analysis trap — measured, and worth more than a success

Adding an `AnalysisTemplate` that curls the app's `/healthz` reported
**`Successful` while a broken pod sat there.** It was not a bug in Rollouts.
Without `trafficRouting` configured there is no separate canary Service, so the
check hit the *stable* Service — still backed by three healthy old pods — and
correctly returned 200.

**Analysis is only meaningful if it can address the canary in isolation, and
that requires a traffic provider.** This is the concrete version of the claim at
the top of this file: canary is a statement about your traffic layer.

### Flagger — architecture confirmed, analysis not completed

Installed with ingress-nginx as provider plus its bundled Prometheus and
loadtester. It initialised and did the thing that surprises people:

```
podinfo           0/0     <- YOUR deployment, scaled to zero
podinfo-primary   2/2     <- Flagger's copy, serving traffic
podinfo-canary            <- service Flagger created to address the canary
```

**Flagger keeps your Deployment object but takes over running it.** Compare Argo
Rollouts, which replaces the Deployment with a different kind entirely.

The analysis run did **not** complete here, and the reason is capacity rather
than configuration — see below. `Canary analysis failed, Deployment scaled to
zero` after `progressDeadlineSeconds`, with events showing
`canary deployment podinfo not ready: waiting for rollout to finish`.

Flagger needs primary (2) + canary (2) + loadtester + Prometheus on top of Argo
CD, Flux, Rollouts and ingress-nginx. That did not fit — for a reason specific
to EKS.

### The EKS constraint that caused it: pods per node, not CPU

```
0/2 nodes are available: 2 Too many pods
cpu 680m (35%)      <- plenty of CPU free
max_pods/node: 17
```

On EKS every pod takes a **real VPC IP from an ENI**, so pod density is capped by
instance type, not by CPU or memory. A `t3.medium` allows **17 pods**. Three
nodes is 51, and the stack above needs more than that once Flagger's four extra
pods arrive.

This is invisible on k3s, which uses an overlay network and will happily pack
pods until it runs out of memory.

**The production fix is prefix delegation, not bigger nodes:**

```bash
kubectl -n kube-system set env daemonset aws-node ENABLE_PREFIX_DELEGATION=true
```

That takes a `t3.medium` from 17 pods to roughly 110, by assigning /28 IP
prefixes to ENIs instead of individual addresses. **It only affects nodes that
join afterwards** — `max-pods` is computed by kubelet at bootstrap, so existing
nodes keep their old ceiling. Verified here: after enabling it, existing nodes
still reported `max_pods: 17`.

To finish the Flagger drill: enable prefix delegation *before* the nodes launch,
or use an instance type with more ENIs.
