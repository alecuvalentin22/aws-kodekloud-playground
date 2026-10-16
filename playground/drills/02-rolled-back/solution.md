ROOT CAUSE
  The merged change set FAIL_HEALTH="true" in k8s/deployment.yaml. app.py
  returns 500 from /healthz when that is set. Readiness never passes, and the
  LIVENESS probe hits the same endpoint, so the kubelet keeps restarting the
  container: the new pod shows CrashLoopBackOff with a growing restart count
  -- although the process itself never crashed. (Verbatim from the Deploy
  stage: `demo-api-6fd976c44c-7n4mn  0/1  CrashLoopBackOff  4 (38s ago)`.)
  With maxUnavailable: 0 the two old pods stay up, the rollout stalls,
  `rollout status` times out, and deployToEks rolls back and fails the build.
  Unit tests cannot catch it: they never run the manifest.

FIX
  Revert the value (git revert <sha> is the honest way), push, watch it deploy.
  NOT acceptable: removing the readiness probe "so it deploys" -- the check
  fails you for that, because the pipeline would then go green on broken pods.

ALSO WORTH SAYING
  Readiness and liveness on the same endpoint turns "not ready" into a
  restart loop. Liveness should answer "is the process wedged", readiness
  "can it take traffic"; a dependency check belongs in readiness only.

WHAT STOPS IT RECURRING
  A smoke test in the pipeline that runs the built image with the real env and
  curls /healthz before deploy, or a staging namespace that deploys first.

SAY THIS IN THE INTERVIEW
  "The pipeline being red was the system working. `kubectl apply` returning
  success means the API server accepted the object, not that the app is up;
  that's why our deploy step waits on `rollout status` and rolls back. I read
  the pod state the step printed, saw readiness failing with 500, found the env
  change in git log, and reverted it. Then I told the developer the pipeline
  had protected prod, and showed them where to see that next time."

  Same failure on EKS: platform-lab drills/18 section 4.
