"Waiting" in Jenkins with Kubernetes agents usually means the agent pod
exists but is not running. Look where the agents live:
  kubectl --context kind-playground -n jenkins get pods
  kubectl --context kind-playground -n jenkins describe pod <the agent pod>
---
Events say FailedScheduling: Insufficient memory. Compare what the pod
REQUESTS with what the node has: kubectl describe node | grep -A8 Allocatable
Who decides the agent pod's size? Not the app team. Look at #platform-changes.
---
The pod template lives in platform-lib (resources/podtemplates/build.yaml).
Revert Jordan's commit there. Then the builds already stuck in the queue are
stuck behind each other (disableConcurrentBuilds): abort them, or let the
next one run once the pod fits.
