# Prometheus, Grafana, Alertmanager

A prerequisite for the APISIX scenarios rather than an end in itself. Scenario
14's whole finding is that a broken canary is invisible in route-level metrics,
and that is not demonstrable without somewhere to look.

## Sized for a four-node lab, and honest about it

`retention: 2h`, no persistence, 30s scrape. Enough to watch a canary roll out
and fail; useless for anything historical. This is not a production monitoring
stack and should not be described as one.

## The flag that does the opposite of what it says

`serviceMonitorSelectorNilUsesHelmValues=false` tells the operator to watch
every ServiceMonitor rather than only those carrying the release's own Helm
labels. It must be passed with `--set`:

```bash
--set   prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false   # correct
--set-string prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false   # BROKEN
```

`--set-string` makes the value the **string** `"false"`, which is truthy in a
Helm template, so the flag silently does nothing. Cost here: half an hour, with
APISIX serving 886 metric lines that nobody was scraping and no error at any
layer — not in the operator logs, not on the targets page, not on the
ServiceMonitor.

Check the resulting object rather than the flag you passed:

```bash
kubectl -n observability get prometheus \
  -o jsonpath='{.items[0].spec.serviceMonitorSelector}'
# {"matchLabels":{"release":"kube-prometheus-stack"}}  <- flag did not take
# {}                                                   <- flag took
```

**The more robust fix is not to rely on the flag at all.** Label the
ServiceMonitor so it matches the default selector:

```bash
kubectl -n apisix label servicemonitor apisix release=kube-prometheus-stack
```

`scripts/apisix-install.sh` does exactly that, so APISIX is scraped whether or
not the other chart's flag behaved.

## A ServiceMonitor can match and still scrape nothing

The chart's own ServiceMonitor used `endpoints[0].targetPort`. That resolves
against the **pod's** ports, not the Service's — so a Service port named
correctly is not sufficient. Prefer `port:` (the Service port name), which is
what the operator documents and what fails loudly when wrong.

## Verify, do not assume

An empty graph and a broken scrape look identical.

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# Status -> Targets, and check nothing unexpected is DOWN
```
