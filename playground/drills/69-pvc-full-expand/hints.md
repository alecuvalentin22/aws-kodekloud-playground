`kubectl -n platform-lab-drill69 logs audit-writer-0 --previous` and read the
first two lines (the `df` it prints at start) and the last one. What is the
kernel saying, and how full is /data?
---
Look at the claim, not the pod: `kubectl -n platform-lab-drill69 get pvc` and
`describe pvc`. How big is it, which StorageClass, and does that class allow
growing a volume? (`kubectl get sc`, column ALLOWVOLUMEEXPANSION.)
---
A PVC can be grown in place by raising `spec.resources.requests.storage`
(`kubectl patch pvc ... -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'`).
Never lower it (not allowed) and do not delete the claim: that deletes the
volume and the audit trail with it. Then watch the PVC conditions
(Resizing, FileSystemResizePending) and `df` inside the pod. Pick a size that
makes sense (EBS volumes can be modified only about once per 6 hours).
