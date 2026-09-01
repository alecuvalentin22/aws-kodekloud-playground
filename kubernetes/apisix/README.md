# Apache APISIX, alongside Kong

Kong stays. The side-by-side is the point, exactly as Argo CD and Flux both
reconcile the same repository into different namespaces: same demo workload,
same auth requirement, same rate limit, so anything that differs is a property
of the gateway rather than of the app.

## The architecture changed under this backlog, and it matters

Most APISIX-ingress material online describes **v1.x**, where the flow was:

```
ApisixRoute CRD  ->  ingress-controller  ->  etcd  ->  APISIX worker (watch)
```

**apisix-ingress-controller 2.x does not talk to etcd at all.** The controller
ships an **ADC** sidecar (`ghcr.io/api7/adc`) and pushes configuration through
the **Admin API**:

```
ApisixRoute CRD  ->  controller + ADC  ->  Admin API  ->  APISIX  ->  etcd  ->  worker
                     \_____ hop A _____/               \____ hop B ____/
```

There are still two independent hops, and they still fail differently — but the
first one is an HTTP call to the Admin API, not an etcd write. Anything that
tells you to look for the controller's etcd connection is describing the old
version.

Two config values shape how the hops behave, and both are worth knowing before
diagnosing a stall:

| value | default | why it matters |
|---|---|---|
| `config.provider.syncPeriod` | `1m` | full resync interval. A control-plane stall can **self-heal** within a minute, which makes it easy to miss |
| `config.provider.initSyncDelay` | `20m` | delay before the first full sync after startup |

## Why etcd is still here

`deployment.mode: traditional` — APISIX keeps its own config in etcd and the
workers watch it. The chart's built-in etcd is explicitly *"only for development
and testing purposes"*; production uses `externalEtcd`.

`standalone` mode removes etcd entirely and is covered separately in T-27.

## HA from the start

Not decoration — scenario 14 disrupts these components on purpose, and a
single-replica gateway cannot show the difference between a control-plane stall
and a data-plane one.

- gateway: 3 replicas, `maxSurge: 0`, anti-affinity, PodDisruptionBudget
- etcd: 3 replicas so a rolling member restart holds quorum at 2/3
- explicit resource requests everywhere: a pod with no request is BestEffort and
  is evicted first under memory pressure, which on a 4 GiB node is a matter of
  when

## The Admin API is deliberately NOT exposed

Every other service in this lab is on a public NodePort. The APISIX **Admin
API** is not, and that is a decision rather than an oversight: it is
authenticated only by a static shared key, and it can rewrite every route in the
gateway. It stays `ClusterIP`.

## Measured

`make scenario ID=13` — control plane vs data plane:

| | gateway | signal | breaks |
|---|---|---|---|
| controller down, CRD changed | serves **stale** config 90s+, `3/3` Ready | **none at all** | correctness |
| etcd down | keeps serving correctly | `HTTP 500 / 503, failed to sync` immediately | ability to change |

Recovery from the control-plane stall took **53s** after the controller
returned, consistent with `syncPeriod: 1m`.

`make scenario ID=14` — the canary blind spot, on a 90/10 split with v2 broken:

| view | success | fires? |
|---|---|---|
| `sum by (route, code)` | 652/663 = **98.3%** | no |
| `sum by (route, code, node)`, v2 only | 36/47 = **76.6%** | yes |

Same samples, same window, one `GROUP BY` apart. APISIX already emits the
upstream `node` label — the blind spot is in the query, not the gateway.
