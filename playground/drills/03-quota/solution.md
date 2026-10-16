ROOT CAUSE
  FinOps applied a ResourceQuota of pods: 2 to demo-ci. The Deployment has 2
  replicas and a RollingUpdate of maxSurge: 1 / maxUnavailable: 0, so every
  rollout needs a THIRD pod. The ReplicaSet controller is refused by the quota
  and records it as a FailedCreate event on the ReplicaSet. No pod object is
  ever created, so `kubectl get pods` and `describe pod` show nothing at all.

FIX (pick one, and say what it costs)
  - Raise the quota to 3 with FinOps (capacity for exactly one surge pod).
  - maxSurge: 0 / maxUnavailable: 1: fits the quota, but every deploy runs at
    half capacity for a while. Fine for this service, not for every service.
  NOT acceptable: deleting the quota. It is not yours.

SAY THIS IN THE INTERVIEW
  "When a pod never appears I go one level up, to the ReplicaSet, because
  that's the thing that would have created it. Its events said 'exceeded
  quota'. The quota belonged to FinOps, so I didn't delete it: I explained the
  surge math to them -- two replicas plus one surge needs three -- and we
  raised it by one. Then I added quota-awareness to our runbook, because the
  symptom, 'nothing happens and nothing errors', sends people to the wrong place."

  Same failure on EKS: platform-lab drills/18 section 12.
