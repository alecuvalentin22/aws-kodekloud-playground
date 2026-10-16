"Nothing in the logs" is rarely true. Open the stuck build's console and
look for lines starting with "Pod [" -- the Kubernetes plugin prints the
agent pod's state while it waits. Or go to the pod directly:
  kubectl --context kind-playground -n jenkins get pods
---
Events say FailedScheduling: Insufficient memory. Compare what the pod
REQUESTS with what the node has: kubectl describe node | grep -A8 Allocatable
Who decides the agent pod's size? Not the app team. Look at #platform-changes.
---
The pod template lives in platform-lib (resources/podtemplates/build.yaml).
Revert Jordan's commit there. Then the builds already stuck in the queue are
stuck behind each other (disableConcurrentBuilds): abort them, or let the
next one run once the pod fits.
Last trap: aborting a build whose agent never connected does NOT delete its
Pending pod straight away. Check `get pods` again after the abort.
