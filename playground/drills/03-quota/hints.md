A pod that never appears was never created. Pods are created by a
ReplicaSet, so the error is on the ReplicaSet, not on any pod:
  kubectl --context kind-playground -n demo-ci get rs
  kubectl --context kind-playground -n demo-ci describe rs <the newest one>
---
Look at the events: FailedCreate ... exceeded quota. What else changed in
this namespace today? (#platform-changes, and `kubectl get resourcequota`)
---
Two honest fixes, both keep the quota: make the rollout fit inside it
(the Deployment's rollingUpdate strategy), or get the quota raised by its
owner -- in the game you may edit it yourself, but say why. Deleting it is
the fix the check penalises.
