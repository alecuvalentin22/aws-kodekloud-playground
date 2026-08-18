# Drill 15 — Four Kubernetes failures from one afternoon

All four happened on a single t3.medium running k3s, on 2026-08-18. None of them
is exotic; all four are things that take down real clusters.

## 1. A liveness probe turned a slow start into an outage

Kong would not install. `helm --wait` eventually gave the least useful error in
the catalogue:

```
Error: UPGRADE FAILED: context deadline exceeded
```

The pod told a better story:

```
kong-kong-669d578f58-98nrw   1/2   CrashLoopBackOff   14 (89s ago)
Liveness probe failed: Get "http://10.42.0.40:10254/healthz": connection refused
```

**1/2** is the clue. The `proxy` container was healthy and serving traffic the
whole time. The `ingress-controller` container needs ~40s to initialise, because
it waits on Kong's admin API — and the chart's default liveness probe gives it
about 30. So:

```
info  setup  Getting the kong admin api client configuration
info  Signal received, shutting down  {"signal": "terminated"}
```

The kubelet killed a container that was merely slow, restarted it, and it was
slower still under the resulting memory pressure.

**Liveness answers "is it broken?" — not "is it ready?"** Readiness gates
traffic; liveness kills. A liveness probe that can fire during a slow start
converts a delay into a restart loop.

```
--set ingressController.livenessProbe.initialDelaySeconds=60
--set ingressController.livenessProbe.failureThreshold=10
--set ingressController.readinessProbe.initialDelaySeconds=30
--wait --timeout 10m
```

## 2. `replicas: 1` still means two pods during a rollout

Updating Keycloak wedged the whole node — sshd stopped completing its banner
exchange, and only an EC2 reboot brought it back. EC2 status checks stayed
**green** throughout, because the hypervisor was fine; only the guest was
starved.

The default `RollingUpdate` strategy computes `maxSurge` from the replica count,
so `replicas: 1` gets `maxSurge: 1` — the new pod starts **while the old one is
still running**. Two Keycloaks at ~1 GiB each, on a 4 GiB node already carrying
k3s, Kong, cert-manager and Rancher. And the `common` role disables swap
(correct, for Elasticsearch), so the box did not degrade — it stopped.

```yaml
spec:
  replicas: 1
  strategy:
    type: Recreate      # old pod terminates BEFORE the new one starts
```

`Recreate` is right whenever a surge cannot help you: single replica, in-memory
state, or a node too small to hold two copies. The default is tuned for
availability, and availability is not free.

## 3. Scaling a webhook to zero does not disarm it — it arms it against you

To free memory, `kubectl scale deploy rancher-webhook --replicas=0`. Then Kong's
install failed:

```
Internal error occurred: failed calling webhook "rancher.cattle.io.secrets":
Post "https://rancher-webhook.cattle-system.svc:443/...": no endpoints available
```

The `ValidatingWebhookConfiguration` and `MutatingWebhookConfiguration` are
**cluster-scoped objects that outlive the pods serving them**. They intercept
every Secret in every namespace, and with `failurePolicy: Fail` and nothing
behind the Service, every Secret creation cluster-wide fails — including for
workloads that have no relationship to Rancher whatsoever.

```bash
helm uninstall rancher -n cattle-system                    # removes the configs
kubectl delete validatingwebhookconfiguration rancher.cattle.io
kubectl delete mutatingwebhookconfiguration rancher.cattle.io
```

This is exactly how a half-removed service mesh or policy controller takes down
deployments months later. **Check for orphaned webhook configurations before
believing something is uninstalled:**

```bash
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations
```

## 4. Disabling the default ingress controller leaves charts with no way in

k3s is installed with `--disable traefik`, because Kong is this lab's gateway
and two controllers fighting over 80/443 is worse than none. But the Rancher
chart only ships an Ingress:

```
$ kubectl get ingressclass
NAME   CONTROLLER
kong   ingress-controllers.konghq.com/kong

$ kubectl -n cattle-system get ingress
NAME      CLASS    HOSTS                          PORTS
rancher   <none>   rancher.98.82.19.61.sslip.io   80, 443
```

`CLASS <none>` — no controller claims it, nothing listens on 443, and the URL
refuses the connection. Rancher was `1/1` and its ClusterIP Service answered
fine; there was simply no path in from outside. A NodePort straight to the pods
bypasses ingress entirely.

## Say this in the interview

> "Kong CrashLoopBackOffed and Helm just said 'context deadline exceeded'. The
> pod showed 1/2 — the proxy was healthy, the ingress controller wasn't. It
> needed about forty seconds to reach Kong's admin API and the liveness probe
> gave it thirty, so the kubelet kept killing a container that was only slow.
> Liveness answers 'is it broken', readiness answers 'can it serve' — mixing
> those up turns a slow start into a restart loop.
>
> The one that surprised me most was scaling Rancher's webhook to zero to free
> memory. The webhook *configurations* are cluster-scoped and outlive the pods,
> so with failurePolicy Fail and no endpoints, every Secret creation in the
> cluster started failing — and what actually broke was Kong, which had nothing
> to do with Rancher."
