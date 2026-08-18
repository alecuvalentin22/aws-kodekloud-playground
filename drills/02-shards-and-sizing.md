# Drill 02 — Shards, replicas and sizing

**The question:** "How many shards should this index have?"

## The rules of thumb worth memorising
- Target **10–50 GB per shard**. Under ~10 GB you are paying overhead; over
  ~50 GB, recovery and rebalancing get slow.
- Keep **shards per node under ~20 per GB of heap**. Every shard costs heap even
  when idle. Thousands of tiny shards ("shard explosion") is the classic way to
  kill a small cluster.
- **Primary count is fixed at index creation.** You cannot change it later — you
  reindex, shrink, split, or roll over. Replica count *is* changeable live.
- Heap: **half of RAM, never above ~31 GB** (above that the JVM loses compressed
  ordinary object pointers and you get *less* usable heap).

## Do this
```bash
# replicas are live-changeable, primaries are not
curl -XPUT "$ES/app-logs-000001/_settings" -H 'Content-Type: application/json' \
  -d '{"index":{"number_of_replicas":2}}'

curl -s "$ES/_cat/nodes?v&h=name,heap.percent,ram.percent,disk.used_percent,node.role"
curl -s "$ES/_nodes/stats/indices?pretty" | jq '.nodes[].indices.docs'
```

Then force a rollover and watch ILM take over:
```bash
curl -XPOST "$ES/app-logs/_rollover?pretty"
curl -s "$ES/app-logs/_ilm/explain?pretty"
```

## Say this in the interview
> "I size for 10–50 GB per shard and use rollover with ILM rather than guessing
> up front, so index size stays bounded regardless of ingest rate. Primaries are
> fixed at creation, so the decision that matters is the rollover threshold."
