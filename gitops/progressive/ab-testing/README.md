# A/B testing on ingress-nginx

## The finding that shaped this directory

The obvious way to do this is an Argo Rollouts `setHeaderRoute` step. It does
not work on nginx, and the controller says so plainly once you try:

```
InvalidSpec: The Rollout "podinfo" is invalid:
  spec.strategy.steps[1].setHeaderRoute: Invalid value: {...}:
  SetHeaderRoute requires TrafficRouting, supports Istio and ALB and Apisix
```

The Rollout goes straight to `Degraded` with **zero replicas** — it never
creates a pod, so there is nothing to debug at the workload level. Note that
`trafficRouting.nginx` **is** supported for weighted canaries (that is what
`../rollouts-nginx/` uses and measures); it is specifically header and mirror
routing that nginx is excluded from.

ALB would work, and is the natural choice on EKS — but the AWS Load Balancer
Controller needs IRSA, and `iam:CreateRole` on this playground is restricted to
three exact role names. So: not a design preference, a permission boundary.

## What is here instead

The header routing itself is an **ingress-nginx** feature, and it needs no
progressive-delivery controller at all — two Ingresses for the same host, one
marked canary:

```yaml
nginx.ingress.kubernetes.io/canary: "true"
nginx.ingress.kubernetes.io/canary-by-header: "X-Cohort"
nginx.ingress.kubernetes.io/canary-by-header-value: "beta"
```

That is the whole mechanism. Argo Rollouts' `setHeaderRoute`, where supported,
writes these same annotations for you and ties them to rollout steps; it does
not implement the routing.

**Precedence matters and is easy to get backwards.** ingress-nginx evaluates
`canary-by-header` **before** `canary-weight`, so a header match wins even at
weight 0. That is what makes A/B possible at all: cohort traffic goes to B while
*no* random traffic does. Get that backwards and you have a canary with extra
steps.

## Why this is not a canary

|  | canary | A/B |
|---|---|---|
| who goes to the new version | a random % of requests | a named cohort |
| stable per user | **no** — same user can flip between versions | **yes** |
| question it answers | is this release safe | does this variant behave differently |
| ends when | the rollout completes | the experiment concludes |

The "stable per user" row is the one that matters. A conversion metric measured
over a randomly re-sampled population is not attributable to anything — you
cannot say a user converted *because of* B if they were only sometimes in B.
Which is also why `canary-by-cookie` exists: a cookie set once keeps a browser
in the same bucket across requests, and a header does not, unless whatever sets
the header is itself sticky.

Both are configured here — header for testing from a terminal, cookie for the
property you would actually want in production.
