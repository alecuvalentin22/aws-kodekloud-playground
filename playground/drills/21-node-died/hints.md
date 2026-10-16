Start with what Kubernetes thinks is wrong, not with the apps:
  kubectl get nodes
  kubectl get pods -A -o wide | grep -v Running
Which node is not Ready, and what do the broken apps have in common?
---
Describe the Jenkins pod (or the registry's). Look at its volume:
  kubectl get pv -o custom-columns=PVC:.spec.claimRef.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]
local-path volumes live on ONE node's disk. Why can't the scheduler just move them?
The nodes are Incus VMs: ssh homelab-1-wsl 'incus list'
---
The node is not destroyed, it is powered off. Bring it back
(ssh homelab-1-wsl 'incus start rke2-a2') and watch the pods recover by themselves.
Do NOT delete a PVC to "unstick" a pod: it comes back on an empty disk.
Then write the answer file: what failed, why only these three, what would
make it survive next time.
