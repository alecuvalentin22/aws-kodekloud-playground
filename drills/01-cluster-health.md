# Drill 01 — Yellow and red

**The question you will be asked:** "Your cluster is yellow. What do you do?"

## Concepts
- **Green** — every primary and every replica shard is assigned.
- **Yellow** — every primary is assigned, at least one replica is not. Data is
  complete and searchable; you have lost redundancy, not data.
- **Red** — at least one *primary* is unassigned. Part of your data is
  unavailable right now. This is the page-someone hour.

A single-node cluster with `number_of_replicas: 1` is permanently yellow, because
a replica may never live on the same node as its primary. That is the most common
"why is my cluster yellow" answer and it is worth being able to say instantly.

## Do this
```bash
curl -s $ES/_cluster/health?pretty
curl -s "$ES/_cat/indices?v&h=health,index,pri,rep,docs.count,store.size"
curl -s "$ES/_cat/shards?v&h=index,shard,prirep,state,node,unassigned.reason"
curl -s "$ES/_cluster/allocation/explain?pretty"      # the one that matters
```

`allocation/explain` tells you *why* a shard will not be assigned. Learn to read
its `decider` output — it is the difference between guessing and diagnosing.

## Break it on purpose
1. `systemctl stop elasticsearch` on es-03. Watch health go yellow, then watch
   replicas re-assign onto the surviving nodes.
2. Start it again. Watch it rejoin and rebalance.
3. Stop two nodes. The cluster loses master quorum (2 of 3) and goes red — this
   demonstrates why you need an odd number of master-eligible nodes.

## Say this in the interview
> "Yellow means replicas are unassigned — data is intact, redundancy isn't. I'd
> check `_cat/shards` for the unassigned reason and run `allocation/explain`.
> Most often it's a node that left, a disk watermark, or replicas that can't be
> placed because there aren't enough nodes."
