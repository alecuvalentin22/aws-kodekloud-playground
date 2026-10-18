ROOT CAUSE (three things, each one hid the next)
  1. The pipeline could not fail on a bad release. Sam removed  --atomic --wait
     --timeout "$TIMEOUT"  from  helm upgrade --install  in Jenkinsfile.helm
     ("deploys take ~4 min") and deleted the Test stage. Without --wait, helm
     returns as soon as the Kubernetes API has ACCEPTED the manifests: the release
     is recorded as "deployed" the moment the YAML is stored, whether or not a
     single pod ever becomes Ready. "Green" meant "the API said yes". The failure
     message in the Jenkinsfile still says "--atomic rolled back to the last good
     revision": it describes behaviour that was removed.
  2. A bad value shipped. Build #2 ran with EXTRA_SET=config.FAIL_HEALTH=true
     ("to test the alert"). The ConfigMap changed, the checksum annotation rolled
     the pods, and the new ones answer /healthz with 500: never Ready.
  3. Staging had just been moved to  strategy: Recreate  (values-staging.yaml:
     "surge pods hit the quota"). With the chart's default RollingUpdate and
     maxUnavailable: 0 the same release would have STALLED beside two healthy old
     pods and the service would have kept answering; Recreate kills the old pods
     first, so the broken release took staging down.
  Result: release revision 3 "deployed", pods 0/1, Service with no ready endpoints,
  Jenkins green.

HOW TO SEE IT
  helm -n helm-drill-83 history demo-api          # 1 superseded, 2 superseded, 3 deployed; descriptions name the build and tag
  helm -n helm-drill-83 get values demo-api --revision 3     # config.FAIL_HEALTH: true   (revision 2: not set)
  kubectl -n helm-drill-83 get pods,endpointslices           # 0/1, endpoints <unset>
  kubectl -n helm-drill-83 describe pod ...                  # Readiness probe failed: HTTP probe failed with statuscode: 500
  git -C ~/platform-playground/helm-drill-83 log -p -- Jenkinsfile.helm values... # Sam's two commits
  Jenkins: build #2's console ends in "helm upgrade ... STATUS: deployed" and SUCCESS, 4 seconds after it started.

FIX, IN THIS ORDER
  1. Recover first. The release record is the rollback target:
         helm -n helm-drill-83 rollback demo-api 2 --wait --timeout 2m
     (revision 2 = last one before FAIL_HEALTH; rollback creates revision 4 with
     revision 2's content; the history stays: 1, 2, 3 superseded, 4 deployed.)
     Rolling forward also works (fix the pipeline, rerun the job without EXTRA_SET),
     but you are then changing the thing that broke production while it is broken.
  2. Make the pipeline unable to ship this again, on the helm upgrade command:
         --atomic --wait --timeout "$TIMEOUT"          (Helm 4 name: --rollback-on-failure)
     and put the Test stage back:  helm -n "$NAMESPACE" test "$RELEASE" --timeout 30s --logs
     Do it as a commit on main, not a local edit.
  3. Prove it, do not trust it: run the job with EXTRA_SET=config.FAIL_HEALTH=true and
     TIMEOUT=60s. Expected: the Deploy stage waits 60 s, Helm gives up, the build is
     FAILURE, helm history shows  failed  (revision 5) then  deployed  "Rollback to 4",
     and staging never stopped answering the previous release's config. That is
     what `play check` runs for real after it has looked at your Jenkinsfile.

NOT ACCEPTABLE
  - helm uninstall + install: it works, and it deletes the history (and the
    rollback targets) in the middle of an incident. (PENALTY 25.)
  - kubectl edit configmap / set env / scale to "fix" the live objects: Helm's record
    still says FAIL_HEALTH=true, the next upgrade is a three-way merge against that.
  - Restoring --wait but leaving the Test stage out. (PENALTY 15.) --wait proves Ready
    pods; helm test proves the SERVICE reaches them (drill 81).
  - Putting the words in a comment, or swallowing the exit code (|| true,
    returnStatus without acting on it): the proof build would come out green.

WHAT STOPS IT RECURRING
  - Atomic + wait + a timeout is the default every pipeline gets: put it in the
    shared library (a helmRelease step) so a team cannot "optimise" it away in its own
    Jenkinsfile, and CODEOWNERS on the deploy stage.
  - Fix the 4-minute deploy instead of removing the safety: shorter readiness delays,
    a smaller --timeout, preloaded images, maxSurge instead of Recreate, quota that
    allows one surge pod.
  - Keep strategy RollingUpdate with maxUnavailable 0 (and a PodDisruptionBudget): it
    limits the blast radius of the failure the pipeline did not catch.
  - A post-deploy gate that asks the SERVICE (helm test, a synthetic probe) and an alert
    on available replicas / endpoints for the Deployment.
  - Flags that make a service unhealthy (FAIL_HEALTH) do not belong in a shared
    environment's job parameters without a guard, or must go through a canary.
  - Argo CD alternative: auto-sync + health assessment + automated rollback by revert.

SAY THIS IN THE INTERVIEW
  "The service was down and the pipeline was green, which told me the pipeline
  was not waiting for the rollout. helm history gave me the last good revision, so
  I rolled back to it before I looked at anything else, with the history intact,
  not uninstall and reinstall. Then the root cause: someone had taken --atomic and
  --wait off the helm upgrade to make deploys faster, and removed the test stage,
  so 'success' just meant the API accepted the YAML; a bad value plus a Recreate
  strategy turned that into an outage. I put the flags back with a timeout and
  restored helm test, and then I proved it by shipping a deliberately broken
  release through the real pipeline: it failed, Helm rolled itself back, and the
  previous release kept serving. For the longer term I would move that deploy
  logic into the shared library so a team can't optimise the safety away, and
  fix the slow deploy rather than the guard."

  Related: drill 41 (green but broken), drill 02 (rollout and rollback), drill 81
  (helm test and the Service), the demo-api chart README ("Releases: install,
  upgrade, rollback, --atomic").
