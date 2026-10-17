ROOT CAUSE
  The 1 Gi EBS volume behind the claim data-audit-writer-0 is 100% full. The
  writer appends a line to /data/audit.log every 2 s; the next time it needs a
  new filesystem block the kernel answers ENOSPC, the shell prints
      sh: write error: No space left on device
  the program exits 1 and the kubelet restarts it with growing back-off:
      audit-writer-0   0/1   CrashLoopBackOff
  (The container's first log line is the df it prints at start:
      /dev/nvme1n1   973.4M   957.4M   0   100% /data )
  Nothing is wrong with the node, the image or the manifest. Here the space
  was taken by a spool backlog file; in production it is log growth, a bigger
  retention window or a burst. A 1 Gi claim is simply too small for it now.
  Note the order of symptoms: the pod does not fail the moment the disk is
  full, only when an append needs a NEW block (ext4 keeps writing into the
  last partly-used block), so it can look healthy for a while.

DIAGNOSE (what to say you ran)
  kubectl -n platform-lab-drill69 get pod                 -> CrashLoopBackOff, restarts climbing
  kubectl -n platform-lab-drill69 logs audit-writer-0 --previous
                                                          -> "No space left on device", df 100%
  kubectl -n platform-lab-drill69 get pvc                 -> 1Gi, StorageClass gp3
  kubectl get sc gp3                                      -> ALLOWVOLUMEEXPANSION true
  (kubectl exec only works in the short windows when the container is up, and
  df/ls inside it show what filled the disk: /data/spool/replay-backlog.ndjson.)

FIX: grow the claim in place (online expansion)
  kubectl -n platform-lab-drill69 patch pvc data-audit-writer-0 \
      -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
  What happens (observed live, gp3, EBS CSI driver, EKS 1.33):
    1. external-resizer calls the CSI controller: ModifyVolume/resize of the EBS
       volume. PVC condition Resizing. ~10 s.
    2. The EBS volume is bigger but the ext4 filesystem on it is not. PVC condition
       FileSystemResizePending: the kubelet on the node runs resize2fs while
       the volume is mounted ("online"). ~10 s later the PVC status.capacity
       says 2Gi and the conditions are gone.
    3. NO pod restart or delete was needed: the pod was in CrashLoopBackOff
       the whole time (the volume stays mounted for the pod sandbox) and the
       next back-off retry started, wrote, stayed Ready. Total ~17 s from patch
       to 2Gi; the pod was Running ~35 s after the patch (back-off timer).
       (If the filesystem did not grow, `kubectl delete pod` makes the kubelet
       re-mount and expand it; that was not needed here.)
  Verify: kubectl get pvc (CAPACITY 2Gi); kubectl exec ... df -h /data (~1.9G);
  the marker file and audit.log history are still there; the writer appends again.
  Optional, and the real prevention: rotation/retention for the spool and an
  alert on kubelet_volume_stats_available_bytes (fire at 80%, not 100%).

LIMITS TO KNOW
  - Only a StorageClass with allowVolumeExpansion: true lets you do this. gp3
    here does; gp2 on this cluster does NOT ("only dynamically provisioned pvc
    can be resized and the storageclass that provisions the pvc must support
    resize"). Changing a class's allowVolumeExpansion is allowed (it is a
    mutable field) but it is a shared object: ask before you touch it.
  - Volumes only grow. You cannot shrink a PVC or an EBS volume.
  - EBS allows one modification per volume about every 6 hours (until the
    volume leaves the "optimizing" state and the cooldown is over, a second
    resize is refused with VolumeModificationRateExceeded). So do not creep
    up 1 Gi at a time: pick the size once, with headroom. In this lab EBS
    volumes are limited to 30 GB each (docs/kodekloud-limits.md), and a
    request over 10 Gi is a PENALTY 20 here.
  - Resize does not need downtime on current EKS, but take a snapshot first when
    the data matters.

THE WRONG FIXES
  - kubectl delete pvc / delete the StatefulSet's volume: the PV reclaim policy
    is Delete, so the EBS volume goes with it. The StatefulSet makes a new,
    empty claim and the pod "works". The audit trail is gone: check FAILS
    (the volume is not the one recorded at the start; the marker is missing).
  - Deleting audit.log or the marker to make room: marker missing is a FAIL; fewer
    lines in audit.log than at the start is PENALTY 15. Deleting the spool backlog
    frees space but does not fix anything: the claim is still 1 Gi, the check
    wants 2 Gi, and it will fill again.
  - Restarting / deleting the pod: it comes back, the volume is still full.
  - Asking for 100 Gi "to be safe": PENALTY 20, and over the lab's 30 GB limit.

WHAT STOPS IT RECURRING
  Alert on kubelet_volume_stats_available_bytes / capacity (< 20% free) so the
  resize is planned, not a 2 a.m. crash loop. Log rotation / retention that
  matches the claim size. Size claims from growth rate x retention + headroom.
  Keep allowVolumeExpansion: true on the default class. A spool that can grow
  without a bound should not share a volume with the data you cannot regenerate.

HOW THIS DRILL MADE THE FAILURE (honest version)
  Real, nothing simulated. break.sh creates namespace platform-lab-drill69 and
  a StatefulSet (busybox 1.37.0) with a 1 Gi gp3 PVC. After the writer has made
  a few lines it writes a marker file, fills the volume with dd into
  /data/spool/replay-backlog.ndjson, and waits for the real CrashLoopBackOff.
  check.sh needs: pod Running+Ready and up >= 30 s, same claim/PV/EBS volume,
  PVC capacity >= 2Gi, df in the pod >= ~1.9G, marker intact, audit.log growing.
  reset.sh deletes the namespace (the CSI driver deletes the volume) and checks
  the recorded volume ID is gone, deleting it by ID if it lingers.

SAY THIS IN THE INTERVIEW
  "A log writer was crash-looping. The logs said 'No space left on device' and
  df showed the 1 Gi EBS volume at 100%. I did not delete the claim, because
  its reclaim policy is Delete and that would have removed the audit trail with
  the volume. gp3 allows volume expansion, so I patched the PVC from 1 to 2 Gi:
  the EBS CSI driver grew the EBS volume, the kubelet grew the ext4 filesystem
  online (FileSystemResizePending), no restart was needed and the pod recovered
  on its own. I picked the size once because EBS only allows one modification
  per volume every six hours, and then added an alert for volume usage at 80%
  and retention for the spool so this does not come back."
