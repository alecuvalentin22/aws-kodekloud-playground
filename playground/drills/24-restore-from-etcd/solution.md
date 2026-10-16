ROOT CAUSE
  A namespace and two objects that existed only in the cluster were deleted.
  Nothing declarative (git, Argo CD) knew about them, so nothing could
  re-create them; the only copy was an etcd snapshot taken just before.

FIX (what the check accepts: the ORIGINAL objects, same UIDs, same value)
  On the RKE2 server:
    systemctl stop rke2-server
    rke2 server --cluster-reset \
      --cluster-reset-restore-path=/var/lib/rancher/rke2/server/db/snapshots/drill24-before-cleanup-...
    systemctl start rke2-server
  On a multi-server cluster you would also stop the other servers, wipe their
  etcd data dir, and re-join them after the restore.

WHAT IT COST
  A cluster restore is ALL OR NOTHING: every object in the cluster goes back
  to the snapshot's moment. Anything created or changed after it (deploys,
  Secrets, Argo CD state, leases) is rolled back. Here the snapshot was seconds
  old, so the cost was ~nothing; with a 6-hour-old snapshot it could be a day's
  deploys. Volumes (PVC data) are NOT in etcd and are not rolled back -- so a
  restore can leave apps' state and Kubernetes' state disagreeing.
  The surgical alternative: start a throwaway etcd from the snapshot (or use
  `etcdutl snapshot restore` into a scratch dir), read just those keys, and
  re-apply them -- but then they come back with NEW UIDs, which is fine for a
  ConfigMap and not always for things other objects reference by UID.

WHAT STOPS IT RECURRING
  Everything in git (the payroll objects should have been: sealed-secrets or
  SOPS for the Secret, as in platform-lab's gitops/secrets/); RBAC so a cleanup
  script cannot delete namespaces it does not own; Velero for namespace-level
  backup/restore (and volumes) instead of whole-cluster etcd restores; frequent
  snapshots before risky operations.

SAY THIS IN THE INTERVIEW
  "etcd restore is the nuclear option: it rewinds the WHOLE cluster to the
  snapshot, so first I checked how old the snapshot was and what had happened
  since. Here it was seconds before the deletion, so I restored -- stop the
  server, cluster-reset with the snapshot path, start it, agents rejoin -- and
  the objects came back with their original UIDs. Then the real fix: those
  objects belonged in git, and a namespace-scoped tool like Velero is the right
  backup for 'someone deleted one namespace'."
