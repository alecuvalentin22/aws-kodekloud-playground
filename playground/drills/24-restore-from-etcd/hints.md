Nothing in git, nothing in Argo CD: the only copy of those objects is in etcd's
past. Find the snapshots (on the server, and the copies off it):
  ssh homelab-1-wsl 'incus exec rke2-s1 -- rke2 etcd-snapshot list'
Which one is from just BEFORE the deletion?
---
RKE2 restores a snapshot by resetting the cluster to it, on the server:
  stop rke2-server, run `rke2 server --cluster-reset --cluster-reset-restore-path=<file>`,
  then start rke2-server again. Agents reconnect by themselves.
Before you do it: what ELSE in the cluster changes back to that moment?
---
On homelab-1 (one server, so no other servers to stop and re-join):
  ssh homelab-1-wsl 'incus exec rke2-s1 -- systemctl stop rke2-server'
  ssh homelab-1-wsl 'incus exec rke2-s1 -- rke2 server --cluster-reset \
      --cluster-reset-restore-path=/var/lib/rancher/rke2/server/db/snapshots/<the drill24 file>'
  (it ends with "restart without --cluster-reset flag now")
  ssh homelab-1-wsl 'incus exec rke2-s1 -- systemctl start rke2-server'
Then check the UIDs, and write down the blast radius.
