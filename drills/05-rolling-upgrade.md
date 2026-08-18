# Drill 05 — Rolling restart and upgrade

The order matters. Get it wrong and the cluster spends an hour rebalancing shards
it was about to get back anyway.

```bash
# 1. stop shard reallocation so a 30-second restart doesn't trigger a rebuild
curl -XPUT "$ES/_cluster/settings" -H 'Content-Type: application/json' \
  -d '{"persistent":{"cluster.routing.allocation.enable":"primaries"}}'

# 2. flush so recovery is fast
curl -XPOST "$ES/_flush"

# 3. restart ONE node
systemctl restart elasticsearch

# 4. wait for it to rejoin
curl -s "$ES/_cat/nodes?v"

# 5. re-enable allocation
curl -XPUT "$ES/_cluster/settings" -H 'Content-Type: application/json' \
  -d '{"persistent":{"cluster.routing.allocation.enable":null}}'

# 6. wait for GREEN before touching the next node
curl -s "$ES/_cluster/health?wait_for_status=green&timeout=300s&pretty"
```

Repeat per node. The playbook's `serial: 1` on the elastic play does exactly this
shape — one node at a time — which is why it is written that way.

**Upgrade rules:** upgrade replicas before primaries is not a thing you control;
what you do control is version order — Kibana is upgraded *after* Elasticsearch,
never before, and you cannot skip major versions.

## Say this in the interview
> "Disable allocation, flush, restart one node, wait for green, re-enable, move
> to the next. The point of disabling allocation is to stop the cluster copying
> gigabytes of shards for a node that will be back in 40 seconds."
