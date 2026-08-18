# Drill 04 — Snapshot and restore

The playbook already registered an S3 repository (`lab-backups`) pointing at
MinIO. Snapshots are incremental at segment level: the second snapshot only
copies segments the first did not.

```bash
# verify the repo is reachable from every node -- this is the usual failure
curl -XPOST "$ES/_snapshot/lab-backups/_verify?pretty"

# take one
curl -XPUT "$ES/_snapshot/lab-backups/snap-$(date +%F-%H%M)?wait_for_completion=true&pretty"

# list, inspect
curl -s "$ES/_cat/snapshots/lab-backups?v"
curl -s "$ES/_snapshot/lab-backups/_current?pretty"

# restore -- an index must be closed or deleted before it can be restored over
curl -XPOST "$ES/app-logs-000001/_close"
curl -XPOST "$ES/_snapshot/lab-backups/SNAPSHOT_NAME/_restore?pretty" \
  -H 'Content-Type: application/json' \
  -d '{"indices":"app-logs-000001"}'
```

**Do the destructive version once.** Delete an index for real, restore it, and
confirm the doc count matches. A restore you have never rehearsed is not a backup —
that sentence is worth saying out loud in an interview, because it is exactly the
attitude an operations team is hiring for.

Then automate it with SLM (snapshot lifecycle management) and let it run nightly.
