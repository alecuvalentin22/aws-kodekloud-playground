ROOT CAUSE
  An EBS volume lives in ONE availability zone and can only be attached to an
  instance in that zone. When the PVC was provisioned, the pod was placed on a
  node in us-east-1b (gp3 is WaitForFirstConsumer: the volume is created in the
  zone of the node the scheduler picked), so the PV got a node affinity:
      Node Affinity: topology.kubernetes.io/zone in [us-east-1b]
  From then on the pod can run only in that zone. This cluster has ONE node per
  AZ. That node went away (here: cordoned and drained; in production an ASG
  scale-in, spot reclaim or AMI roll that brought the replacement up in another
  AZ). The other two nodes are idle and big enough, but the scheduler may not use
  them. The pod is Pending and the Events say so:
      0/3 nodes are available: 1 node(s) were unschedulable, 2 node(s) didn't match
      PersistentVolume's node affinity.
  (Kubernetes 1.33 wording. Older versions: "had volume node affinity conflict".
  With a node really gone it would read "3 node(s) ... node affinity" -- the
  "unschedulable" part here is the cordon.)
  WaitForFirstConsumer does NOT prevent this: it chooses the zone once, at first
  placement. After that the zone is a property of the data.

DIAGNOSE (what to say you ran)
  kubectl -n ledger describe pod ledger-db-0        -> FailedScheduling, node affinity
  kubectl get nodes -L topology.kubernetes.io/zone  -> which zones have a schedulable node
  kubectl get pv <name> -o yaml | grep -A8 nodeAffinity   -> the zone the data is pinned to
  aws ec2 describe-volumes --volume-ids <id>        -> AvailabilityZone, State (available = detached)

FIX A: give the volume's AZ a node again  (cheapest; use when the zone can have a node)
  Here: kubectl uncordon <the node in that zone>; the pod schedules, attaches the
  volume, postgres replays nothing (it was stopped cleanly) and the rows are there.
  Production: a node in that AZ. Make the ASG / managed node group able to place
  one there again (capacity in that AZ, an instance type that exists there, fix the
  launch failure), or one node group PER AZ for stateful workloads so a replacement
  always comes back to the same zone.
  Use A when the data is big, the zone is healthy and you can get a node in it.

FIX B: move the data to a zone that has capacity  (use when the zone cannot get a node:
  AZ outage, no capacity for the instance type, you are shrinking to fewer AZs)
  1. SNAPSHOT FIRST. The old PV has reclaimPolicy Delete: deleting its PVC deletes
     the EBS volume. The pod is Pending, so the volume is detached and the snapshot
     is consistent (postgres was stopped cleanly).
       VOL=$(kubectl get pv <pv> -o jsonpath='{.spec.csi.volumeHandle}')
       SNAP=$(aws ec2 create-snapshot --volume-id $VOL --query SnapshotId --output text)
       aws ec2 wait snapshot-completed --snapshot-ids $SNAP
  2. A volume from it in a zone with a schedulable node (gp3, <= 30 GB on this account):
       NEW=$(aws ec2 create-volume --availability-zone us-east-1a --snapshot-id $SNAP \
             --volume-type gp3 --query VolumeId --output text)
       aws ec2 wait volume-available --volume-ids $NEW
     (An encrypted snapshot gives an encrypted volume; the node role / CSI driver
     needs kms access to the key -- the default aws/ebs key worked here.)
  3. Stop the StatefulSet, drop the old claim, hand-write a PV and the claim that
     the StatefulSet expects to find (same name: data-ledger-db-0):
       kubectl -n ledger scale sts ledger-db --replicas=0
       kubectl -n ledger delete pvc data-ledger-db-0      # old volume goes with it; the snapshot is the safety net
       PV: spec.csi {driver ebs.csi.aws.com, volumeHandle $NEW, fsType ext4},
           spec.nodeAffinity zone In [us-east-1a]  (the NEW zone),
           storageClassName gp3, claimRef ledger/data-ledger-db-0,
           persistentVolumeReclaimPolicy Retain (so a later PVC delete cannot wipe it)
       PVC data-ledger-db-0: same storageClassName, volumeName <the PV>, 1Gi
       kubectl -n ledger scale sts ledger-db --replicas=1
  4. Verify the ROWS, not just Running: psql -c "select count(*) from entries".
  The cordoned node does not need to come back in B: it stands for a node that no
  longer exists. Tidy up afterwards: delete the snapshot when it is no longer
  needed, and note the PV is Retain (a leftover volume costs money).
  Verified live on this account 2026-10-17: ec2:CreateSnapshot / CreateVolume /
  CreateTags are all allowed here (dry-run first, then real).

THE SHORTCUT THAT LOSES THE DATA
  kubectl delete pvc / delete pv "to unstick it". The StatefulSet creates a NEW
  empty claim, WaitForFirstConsumer provisions a fresh volume in whatever zone has a
  node, the pod goes Running and Ready, nobody notices -- and the ledger is empty,
  the old volume gone (reclaim policy Delete). check.sh reads the marker row the
  drill wrote: Running on an empty volume FAILS.

HOW THIS DRILL MADE THE FAILURE (honest version)
  No instance is terminated or launched: the account's EC2 budget is 5 x t3.medium
  and 3 are in use. break.sh picks an AZ with no PVC-backed pod (so Jenkins and
  Gitea, pinned to their own zones, are untouched), cordons the other nodes while it
  creates the StatefulSet (so the pod and volume land in that zone without a
  nodeSelector in the manifest), writes a marker row plus 250 entries, uncordons,
  then cordons and drains the node of that zone. Same scheduler state as a node
  replacement that came up in another AZ.

WHAT STOPS IT RECURRING
  - One node group (ASG) per AZ for stateful workloads, with min >= 1 each, so a
    replacement comes back in the same zone. A single multi-AZ ASG rebalances and
    replaces nodes anywhere. Karpenter: constrain NodePools by zone, or let it read
    the PV's topology (it does) -- but it still needs capacity in THAT zone.
  - topologySpreadConstraints / replicas across zones for anything that can
    replicate (postgres with a replica, not one pod on one disk). The real fix for a
    database is not a bigger recovery procedure: managed Multi-AZ (RDS/Aurora) or
    streaming replication, plus backups: "no recent backup" in the ticket is the
    second finding. Snapshot schedules (Data Lifecycle Manager / AWS Backup / Velero
    with the CSI snapshot class).
  - EFS (efs.csi.aws.com is installed on this cluster) is regional: mount targets
    in every AZ, so a pod can run in any zone and reach the same files. That is the
    answer for SHARED files (uploads, build caches, ML artifacts), with ReadWriteMany
    and no zone pinning. It is not a database disk: NFS latency and locking
    semantics are wrong for postgres. Say both halves.
  - Alert on pods Pending > 5 min with FailedScheduling, and on ASG zone imbalance.
  - Pod disruption: PDB, drain one node at a time, and check "which volumes live in
    this zone" before a node refresh.

SAY THIS IN THE INTERVIEW
  "Pending with plenty of free CPU on other nodes means the scheduler had a
  constraint, so I read the event to the end: nodes didn't match the
  PersistentVolume's node affinity. EBS is zonal; the PV was pinned to us-east-1b,
  and the only node in that zone had been replaced, with the new one in another AZ.
  I did not delete the PVC -- that gives you a Running pod on an empty disk and an
  incident a week later. First choice was to get a node back in the volume's AZ.
  If the zone can't get capacity, I snapshot the volume, restore it in a zone with
  a node, bind a static PV to it, and verify the rows. To stop it recurring: a
  node group per AZ for stateful workloads, replication or a managed Multi-AZ
  database instead of one disk, backups, and EFS where the thing being shared is
  files rather than a database."
