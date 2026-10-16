ROOT CAUSE
  A platform-lib commit raised the BuildKit container's memory REQUEST to 6Gi.
  The scheduler places pods by requests, not by use, and no node has 6Gi
  allocatable, so every agent pod sits Pending with FailedScheduling:
  "Insufficient memory". Jenkins shows the build as waiting for an agent.
  Because the pod template lives in the shared library, one commit stalled
  every team at once.

FIX
  Revert the commit in platform-lib (git revert, then push). Abort the builds
  that are queued behind the stuck one (disableConcurrentBuilds keeps them
  in line). Next build schedules normally.

WHAT STOPS IT RECURRING
  - Requests for what a build NEEDS; limits for the ceiling. A big Java build
    should get its own pod template (e.g. `buildPod: 'java-large'`) instead of
    making every Python build reserve 6Gi.
  - Pin teams to a library tag, and roll library changes out on a canary job
    first (drill 07).

SAY THIS IN THE INTERVIEW
  "'Waiting for an executor' with Kubernetes agents is a scheduling question,
  so I looked at the agent pod, not at Jenkins. It was Pending, insufficient
  memory: the request had been bumped to 6Gi in our shared pod template. I
  reverted it, cleared the queue, and proposed a separate large pod template
  for the Java teams, so one team's needs don't set everyone's reservation."

  Same failure on EKS: platform-lab drills/18 section 6.
