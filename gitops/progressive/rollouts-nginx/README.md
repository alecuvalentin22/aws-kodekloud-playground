# Argo Rollouts with real traffic routing

This directory exists because `../rollouts/` has a bug that is worth keeping.

`../rollouts/` runs a canary with no traffic provider. Its `AnalysisTemplate`
curls `http://podinfo.demo-rollouts:9898/healthz` — the one Service that selects
**every** pod, canary and stable alike. With 1 canary pod out of 4, a curl has a
75% chance of landing on a healthy old pod, and the check is repeated until it
passes. Measured: **`AnalysisRun: Successful` while a broken pod sat in
`ImagePullBackOff`.**

That is not an Argo Rollouts bug. It is the direct consequence of a documented
sentence — *"without a traffic provider, weights are approximated by replica
count"* — that is easy to read past. **Analysis is only meaningful when there is
something for it to analyse separately.**

## What changes here

| `../rollouts/` | this |
|---|---|
| one Service, selects all pods | `podinfo-stable` + `podinfo-canary`, each pinned to one ReplicaSet |
| weight = replica ratio | weight = an `nginx.ingress.kubernetes.io/canary-weight` annotation |
| analysis hits the shared Service | analysis hits `podinfo-canary` only |
| broken release → stuck `Progressing` | broken release → `Degraded`, **automatic rollback** |

The controller pins the Services itself: it appends
`rollouts-pod-template-hash` to each Service's selector on every step. Nothing
in this directory does that by hand — which is exactly why the two Services must
be declared with a bare `app:` selector and left alone.

## The second Ingress you did not write

Argo Rollouts creates `podinfo-canary-ingress` from the stable one, adds
`nginx.ingress.kubernetes.io/canary: "true"`, and moves `canary-weight` as the
rollout steps. Watch it change:

```bash
kubectl -n demo-rollouts-nginx get ingress -w
kubectl -n demo-rollouts-nginx get ingress podinfo-canary-ingress \
  -o jsonpath='{.metadata.annotations}' | python3 -m json.tool
```

If that Ingress never appears, the rollout is silently running weight-by-replica
again — check `kubectl -n demo-rollouts-nginx describe rollout podinfo` for a
`trafficRouting` error rather than trusting the step counter.

## progressDeadlineAbort — the one-line fix for "capped but stuck"

The earlier measurement was: a broken image *contained* the blast radius at 25%
and then **sat there Progressing forever**. Steps pause; they do not judge.

`progressDeadlineSeconds` alone does not fix that — by default Rollouts only
*marks* the rollout `Degraded` and keeps the canary in place.
`progressDeadlineAbort: true` is what makes it actually abort and shift traffic
back to stable. Both are set here.

So there are two independent safety nets, and it is worth being able to name
which one caught a given failure:

- **analysis** catches a release that is *running but wrong* (errors, latency)
- **progressDeadlineAbort** catches a release that *never becomes ready at all*
