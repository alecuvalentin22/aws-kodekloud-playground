ROOT CAUSE
  rke2-a2 died (powered off hard). Jenkins, the image registry and Artifactory
  all keep their data on local-path volumes on rke2-a2's own disk. A local-path
  PV carries nodeAffinity to that node, so their pods cannot be rescheduled
  anywhere else: the scheduler reports "volume node affinity conflict" and the
  pods stay Pending. A StatefulSet pod on a dead node is not even replaced:
  it sits Terminating/Unknown, because Kubernetes cannot prove the old one has
  stopped (at-most-one semantics). demo-api kept answering because it has no
  volume and replicas on other nodes.

FIX
  Bring the node back: ssh homelab-1-wsl 'incus start rke2-a2'. The kubelet
  reconnects, the old pods are reconciled, and the three apps return with
  their data. NOT acceptable: deleting the PVC (or the PV) so the pod can
  schedule elsewhere -- it starts on an empty disk; the check looks for that.
  If the node were really gone: restore the data from a backup onto a new
  volume, or accept the loss knowingly.

WHAT STOPS IT RECURRING
  Replicated or network storage for stateful apps (Longhorn, Ceph, NFS/RWX),
  or external managed state (S3, RDS, an artifact store outside the cluster);
  spread stateful apps across nodes so one node does not hold all of them;
  backups of the volumes (this lab only snapshots etcd -- homelab/README.md).
  An alert on node NotReady, not only on app probes.

SAY THIS IN THE INTERVIEW
  "The symptom said 'three apps down', the cause was one node. I looked at
  nodes first, then at what the broken pods had in common: their volumes were
  local-path on the dead node, so Kubernetes could not move them -- by design,
  because the data was physically there. I brought the node back instead of
  deleting PVCs, which would have 'fixed' it with empty disks. The real fix is
  storage that is not tied to one node, or state that lives outside the
  cluster."
