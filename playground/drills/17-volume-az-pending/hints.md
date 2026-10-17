`kubectl -n ledger describe pod ledger-db-0` and read the Events at the bottom.
Read the scheduler's sentence to the end: it counts nodes and gives a reason for
each group. Then: `kubectl get nodes -L topology.kubernetes.io/zone`.
(Lab credentials for the aws CLI: set -a; . ~/.config/platform-lab/aws-lab-creds.env; set +a)
---
Look at the volume, not the pod: `kubectl get pv` then `kubectl describe pv <name>`
and read "Node Affinity". Then `aws ec2 describe-volumes --volume-ids <id>` and read
AvailabilityZone. An EBS volume exists in exactly ONE availability zone and can only
be attached to an instance in that zone. Which nodes are in that zone right now?
---
Two honest fixes, one dangerous shortcut (deleting the PVC: the StatefulSet makes a
new, empty one and the pod starts happily on the wrong data).
A. give the volume's zone a schedulable node again (here: that is the cordoned node;
   in production, a node in that AZ).
B. move the data: `aws ec2 create-snapshot` -> `create-volume` in a zone that has
   capacity -> a static PV (csi.volumeHandle, nodeAffinity for the NEW zone) -> a PVC
   named data-ledger-db-0 bound to it with volumeName. Snapshot BEFORE you touch the
   old PVC: its PV reclaim policy is Delete.
Check afterwards that the rows are still there, not only that the pod is Running.
