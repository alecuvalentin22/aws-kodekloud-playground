# QUESTION: With a real traffic provider, does Argo Rollouts roll a bad release BACK?
# EXPECT: Yes -- but TWO different mechanisms do it, and each is blind to the other's failure.
#
# Scenario 05 measured "blast radius capped at 25%, then stuck Progressing
# forever". Fixing that turned out to need two unrelated changes, and finding
# out which one did what is the point of this scenario.
#
#   part 1  broken image, never becomes ready  -> caught by progressDeadlineAbort
#   part 2  healthy but SLOW                   -> caught by the AnalysisTemplate
#
# The non-obvious half: in part 1 the analysis reports SUCCESSFUL, even with
# traffic routing configured. Argo Rollouts only re-points podinfo-canary at the
# new ReplicaSet once that ReplicaSet has AVAILABLE pods -- so a canary stuck in
# ImagePullBackOff leaves both Services on the stable pod-template-hash, and the
# analysis measures stable pods and passes. Correctly. There is no canary yet.
#
# Which is why progressDeadlineAbort is not redundant with analysis, and why a
# rollout with only one of the two has a blind spot.
#
# MEASURED on EKS v1.33, ingress-nginx 4.15.1, argo-rollouts v1.9.1:
#
#   part 1  broken image, from a FRESH ReplicaSet
#     t+131s  Degraded, "RolloutAborted", weight 0, broken ReplicaSet scaled to 0
#     (progressDeadlineSeconds is 120; the extra ~11s is reconcile lag. A first
#      run measured 100s. Treat it as "the deadline, give or take a reconcile",
#      not as a precise figure.)
#     analysisrun: Successful  <- and correctly so; both Services still carried
#     the stable pod-template-hash, because the canary RS never had a ready pod
#
#   part 2  --random-delay 2-3s, readinessProbe timeoutSeconds 6
#     t+20s   canary Service re-pointed to the new hash, weight 25
#     t+40s   analysis job: "canary within 1s: 0/30 = 0%"
#     t+50s   Degraded, analysis Failed, weight 0, canary Service back to stable
#
#   50 SECONDS from a bad release to a completed rollback, with no human.
#   The pod was Ready and passing its probes the whole time.

_ns=demo-rollouts-nginx

_img()   { kubectl -n "$_ns" get rollout podinfo -o jsonpath='{.spec.template.spec.containers[0].image}'; }
_phase() { kubectl -n "$_ns" get rollout podinfo -o jsonpath='{.status.phase}'; }
_weight(){ kubectl -n "$_ns" get ingress podinfo-podinfo-canary \
             -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary-weight}' 2>/dev/null; }
_analysis(){ kubectl -n "$_ns" get analysisrun --sort-by=.metadata.creationTimestamp \
             --no-headers 2>/dev/null | tail -1 | awk '{print $2}'; }

# Where analysis job output is collected as it happens.
_ANALYSIS_LOG="${TMPDIR:-/tmp}/scenario06-analysis.$$"

# Print what the controller is doing until it settles.
#
# It also scrapes the analysis job logs on every tick, because Argo Rollouts
# garbage-collects those pods shortly after the AnalysisRun ends. Reading them
# afterwards returns either nothing or -- worse -- the logs of an EARLIER run,
# which is how the first version of this scenario printed "100%" three times
# while the run it was describing had failed at 0%.
_watch() {
  local label="$1" max="${2:-24}" i phase p
  : > "$_ANALYSIS_LOG"
  for i in $(seq 1 "$max"); do
    sleep 10
    for p in $(kubectl -n "$_ns" get pods -o name 2>/dev/null | grep 'canary-'); do
      kubectl -n "$_ns" logs "$p" 2>/dev/null | grep -h 'within 1s' >> "$_ANALYSIS_LOG"
    done
    phase=$(_phase)
    printf "      t+%-4ss phase=%-12s weight=%-4s analysis=%-12s %s\n" \
      "$((i*10))" "${phase:-?}" "$(_weight)" "$(_analysis)" \
      "$(kubectl -n "$_ns" get rollout podinfo -o jsonpath='{.status.message}' 2>/dev/null | cut -c1-30)"
    [[ "$phase" == "Degraded" ]] && break
    [[ "$phase" == "Healthy" && $i -gt 2 ]] && break
  done
  sort -u "$_ANALYSIS_LOG" -o "$_ANALYSIS_LOG" 2>/dev/null || true
}

# Report from what was read, never from what was expected.
# For part 2 the image is IDENTICAL on both sides -- only the args differ -- so
# the marker is searched in the running pods' full container spec, not the tag.
_verdict() {
  local want_phase="$1" bad_marker="$2" phase serving i
  # Aborting is not instantaneous: the controller marks the rollout Degraded and
  # THEN scales the bad ReplicaSet down. Sampling immediately catches that gap
  # and reports "not rolled back" about a rollback in progress -- which is
  # exactly what the first run of this scenario did.
  for i in $(seq 1 18); do
    kubectl -n "$_ns" get rs -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.spec.template.spec.containers[0].image}{.spec.template.spec.containers[0].args}{"\n"}{end}' 2>/dev/null \
      | grep -q -- "$bad_marker" || break
    sleep 10
  done
  phase=$(_phase)
  serving=$(kubectl -n "$_ns" get pods -l app=podinfo \
              -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.spec.containers[0].image}{" "}{.spec.containers[0].args}{"\n"}{end}' \
              2>/dev/null | sort -u | tr '\n' ' ')
  echo "      phase=$phase"
  echo "      running (image + args): ${serving:-<none>}"
  echo "      replicasets: $(kubectl -n "$_ns" get rs --no-headers -o custom-columns='N:.metadata.name,D:.spec.replicas' | tr '\n' ' ')"
  if [[ "$phase" == "$want_phase" && "$serving" != *"$bad_marker"* ]]; then
    echo "      -> ROLLED BACK: $want_phase, and the bad release is serving nothing."
  else
    echo "      -> NOT rolled back as expected (wanted $want_phase, bad marker '$bad_marker')."
  fi
}

_wait_healthy() {
  local i
  for i in $(seq 1 30); do
    [[ "$(_phase)" == "Healthy" ]] && return 0
    sleep 10
  done
  return 1
}

scenario_apply() {
  [[ "$CTL" == "argocd" ]] || { echo "    (Argo Rollouts only -- Flagger is scenario 07)"; return 0; }
  kubectl -n "$_ns" get rollout podinfo >/dev/null 2>&1 || {
    echo "    not installed: kubectl apply -f gitops/progressive/rollouts-nginx/"; return 1; }
  echo "    baseline: image=$(_img) phase=$(_phase)"
}

scenario_observe() {
  [[ "$CTL" == "argocd" ]] || return 0

  # -------------------------------------------------------------------------
  echo
  echo "    PART 1 -- a release that never becomes ready (image tag does not exist)"
  # kubectl `set image` cannot touch a CRD: it resolves types against its own
  # compiled-in scheme, not API discovery. patch goes to the API server.
  kubectl -n "$_ns" patch rollout podinfo --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"ghcr.io/stefanprodan/podinfo:0.0.0-broken"}
  ]' 2>&1 | sed 's/^/      /'
  [[ "$(_img)" == *0.0.0-broken* ]] || { echo "      the break did not land; stopping."; return 1; }

  _watch "part1" 24
  kubectl -n "$_ns" get analysisrun --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null \
    | tail -1 | sed 's/^/      analysisrun: /'
  echo "      canary Service selector: $(kubectl -n "$_ns" get svc podinfo-canary -o jsonpath='{.spec.selector}')"
  echo "      stable Service selector: $(kubectl -n "$_ns" get svc podinfo-stable -o jsonpath='{.spec.selector}')"
  echo "      ^ SAME hash. The canary Service was never re-pointed, because the"
  echo "        canary ReplicaSet never had an available pod. So the analysis"
  echo "        measured stable pods and passed. progressDeadlineAbort caught it."
  _verdict Degraded broken

  # -------------------------------------------------------------------------
  echo
  echo "    restoring, then PART 2 -- a release that is HEALTHY but too slow"
  kubectl -n "$_ns" patch rollout podinfo --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"ghcr.io/stefanprodan/podinfo:6.7.1"}
  ]' >/dev/null 2>&1
  kubectl argo rollouts promote podinfo -n "$_ns" --full >/dev/null 2>&1
  _wait_healthy || echo "      (did not return to Healthy; part 2 may be noisy)"

  # A 2-3s delay on every response. The readiness probe (timeoutSeconds: 6)
  # still passes, so the pod is Ready, the ReplicaSet becomes available, and
  # Argo Rollouts DOES re-point podinfo-canary at it -- which is what makes the
  # analysis able to see this failure and not the one in part 1.
  #
  # --random-error was tried first and does not work: it fails /readyz as well,
  # so the pod never becomes ready and it degenerates into part 1.
  # `command` as well as `args`, and it is not optional. The podinfo image has
  # no ENTRYPOINT, so its command comes from CMD -- and setting `args` alone
  # REPLACES CMD rather than appending to it. The container then tries to exec
  # "--random-delay" as a binary and CrashLoopBackOffs:
  #
  #   exec: "--random-delay": executable file not found in $PATH
  #
  # which turns the intended "healthy but slow" test back into part 1's
  # "never becomes ready", silently.
  echo "      shipping podinfo --random-delay 2-3s (Ready, but violates a 1s SLO)"
  kubectl -n "$_ns" patch rollout podinfo --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/command","value":["/home/app/podinfo"]},
    {"op":"add","path":"/spec/template/spec/containers/0/args","value":["--random-delay","--random-delay-min","2","--random-delay-max","3"]}
  ]' 2>&1 | sed 's/^/      /'

  _watch "part2" 30
  echo
  echo "      what the analysis jobs actually measured (captured live):"
  if [[ -s "$_ANALYSIS_LOG" ]]; then
    sed 's/^/        /' "$_ANALYSIS_LOG"
  else
    echo "        (no job output captured -- the AnalysisRun never reached a job)"
  fi
  kubectl -n "$_ns" get analysisrun --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null \
    | tail -1 | sed 's/^/      analysisrun: /'
  _verdict Degraded random-delay

  echo
  echo "    -> part 1 aborted by progressDeadlineAbort, analysis blind to it"
  echo "    -> part 2 aborted by analysis, progressDeadline blind to it"
  echo "    -> a canary configured with only one of the two has a blind spot"
}

# A FULL reset, and the ReplicaSet deletion is the load-bearing part.
#
# `undo` + restoring the image is not enough. Argo Rollouts keys a ReplicaSet by
# pod-template hash, so re-shipping a template it has seen before REUSES the old
# ReplicaSet -- and on a reused ReplicaSet the progress deadline behaves
# differently. Measured on one cluster, same manifests, same Healthy baseline:
#
#   fresh ReplicaSet      broken image aborted at t+131s   (deadline is 120s)
#   pre-existing one      still Progressing at t+420s, never aborted
#
# So a second run of part 1 without this cleanup measures nothing, and looks
# like progressDeadlineAbort being unreliable rather than a dirty baseline.
# revisionHistoryLimit: 2 does not save you -- it caps history, and two is
# already enough to hit the reuse.
scenario_reset() {
  [[ "$CTL" == "argocd" ]] || return 0
  kubectl -n "$_ns" patch rollout podinfo --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"ghcr.io/stefanprodan/podinfo:6.7.1"}
  ]' >/dev/null 2>&1
  kubectl -n "$_ns" patch rollout podinfo --type=json -p='[
    {"op":"remove","path":"/spec/template/spec/containers/0/args"}
  ]' >/dev/null 2>&1
  kubectl -n "$_ns" patch rollout podinfo --type=json -p='[
    {"op":"remove","path":"/spec/template/spec/containers/0/command"}
  ]' >/dev/null 2>&1
  kubectl argo rollouts promote podinfo -n "$_ns" --full >/dev/null 2>&1

  # Wait for the good template to be serving, THEN drop every ReplicaSet that is
  # scaled to zero, so the next run cannot reuse one.
  local i
  for i in $(seq 1 30); do
    [[ "$(_phase)" == "Healthy" ]] && break
    sleep 10
  done
  kubectl -n "$_ns" delete rs \
    $(kubectl -n "$_ns" get rs -o jsonpath='{range .items[?(@.spec.replicas==0)]}{.metadata.name}{" "}{end}' 2>/dev/null) \
    >/dev/null 2>&1
  return 0
}
