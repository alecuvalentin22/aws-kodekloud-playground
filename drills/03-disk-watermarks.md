# Drill 03 — Disk watermarks

**The question:** "Disk hit 90%. What happens?"

| Threshold | Default | Behaviour |
|---|---|---|
| low | 85% | No *new* shards allocated to that node |
| high | 90% | Elasticsearch actively moves shards *off* that node |
| flood_stage | 95% | Every index with a shard on that node goes **read-only** |

Flood stage is the one that causes the incident. Your application starts throwing
`cluster_block_exception` on writes, and — this is the part people forget —
**the block does not clear by itself when disk frees up.** You must release it:

```bash
curl -XPUT "$ES/_all/_settings" -H 'Content-Type: application/json' \
  -d '{"index.blocks.read_only_allow_delete": null}'
```

## Break it on purpose

Terraform gives each node a small dedicated EBS data volume mounted at
`/var/lib/elasticsearch` (`data_volume_gb`, 10 GiB by default). Filling **that**
rather than the root disk is what makes this drill safe and fast: 10 GiB trips
flood stage in seconds, and when it does, sshd, apt and journald keep working
because they live on a different volume.

```bash
ssh ubuntu@<es-01>
df -h /var/lib/elasticsearch          # confirm it is the EBS volume, not /
```

Fill it to ~96% — leave a sliver, because `fallocate`ing the disk to exactly 0
bytes free can wedge Elasticsearch hard enough that it cannot even write the log
line telling you what happened:

```bash
AVAIL_MB=$(df -m --output=avail /var/lib/elasticsearch | tail -1)
sudo fallocate -l $(( (AVAIL_MB - 400) ))M /var/lib/elasticsearch/ballast

watch -n2 'curl -s "$ES/_cat/allocation?v"'   # watch disk.percent cross 85, 90, 95
```

Now try to write, and watch it fail:

```bash
curl -s -XPOST "$ES/app-logs/_doc" -H 'Content-Type: application/json' \
  -d '{"@timestamp":"2025-01-01T00:00:00Z","message":"should be blocked"}' | jq .
# -> cluster_block_exception ... index read-only / allow delete (api)
```

Then recover, and notice it takes **two** steps:

```bash
sudo rm /var/lib/elasticsearch/ballast
df -h /var/lib/elasticsearch                  # space is back

curl -s -XPOST "$ES/app-logs/_doc" -H 'Content-Type: application/json' \
  -d '{"@timestamp":"2025-01-01T00:00:00Z","message":"still blocked"}' | jq .
# -> STILL cluster_block_exception. Free space did not clear the block.

curl -s -XPUT "$ES/_all/_settings" -H 'Content-Type: application/json' \
  -d '{"index.blocks.read_only_allow_delete": null}' | jq .
# now writes succeed
```

### Growing the volume instead

The other half of the runbook, and the reason a separate EBS volume is worth
having: you can resize it live, with the filesystem mounted.

```bash
# from your laptop
aws ec2 modify-volume --volume-id <vol-id> --size 20

# on the node -- the volume is bigger, but the FILESYSTEM is not, until you say so
lsblk                                          # device shows 20G
df -h /var/lib/elasticsearch                   # still shows 10G
sudo resize2fs /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<volid>   # ext4
# sudo xfs_growfs /var/lib/elasticsearch                                 # xfs
df -h /var/lib/elasticsearch                   # now 20G
```

No downtime, no unmount. Being able to say "grow the volume, grow the
filesystem, then clear the block" is a better answer than "delete old indices".

> **Watch the quota.** A modified EBS volume cannot be modified again for 6
> hours, and the playground's EBS allowance is small. Do this one last.

## Say this in the interview
> "At 95% flood stage indices go read-only, and the block persists after you free
> space — you have to clear `read_only_allow_delete` explicitly. So the runbook
> is: free space, then clear the block, then verify writes."
