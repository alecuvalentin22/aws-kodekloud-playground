# QUESTION: Does Flagger complete a canary and roll a bad one back WITHOUT being told?
# EXPECT: Yes on both. Flagger is metric-driven; Argo Rollouts steps are time-driven.
#
# The structural difference this scenario is really testing:
#
#   Argo Rollouts  steps are a SCRIPT. setWeight 25, pause 30s, setWeight 50.
#                  The controller advances on a timer and only stops if an
#                  AnalysisTemplate you attached says stop. Analysis is optional.
#
#   Flagger        steps are a CONSEQUENCE. stepWeight 10 says how far to move
#                  IF the metrics pass; every interval it re-checks
#                  request-success-rate and request-duration, and after
#                  `threshold` failures it rolls back. Analysis is not optional
#                  -- it is the loop.
#
# Flagger also rewrites your topology on first sight, which is startling:
# it COPIES your Deployment to podinfo-primary, scales YOUR Deployment to 0,
# and points the stable Service at the primary. Your object still exists; it is
# just no longer what serves traffic.
#
# MEASURED on EKS v1.33, flagger 1.44.0, ingress-nginx 4.15.1:
#
#   part 1  good release (6.7.1 -> 6.9.4)
#     t+30s  Progressing weight 10      <- stepWeight, one step per interval
#     t+45s  weight 20
#     t+60s  weight 30
#     t+75s  weight 40
#     t+90s  weight 50                  <- maxWeight reached
#     t+105s Promoting
#     t+135s Finalising
#     t+150s Succeeded, weight back to 0
#
#   part 2  bad release, 500s injected into the canary's traffic
#     t+15s  weight 10  failedChecks 1
#     t+30s  weight 10  failedChecks 2  <- weight NEVER advances past 10
#     t+75s  weight 10  failedChecks 5  <- threshold
#     t+90s  Failed, weight 0, rolled back
#
#   90 SECONDS from a bad release to a completed rollback, on metrics alone,
#   with no AnalysisTemplate written anywhere. Compare Argo Rollouts in
#   scenario 06, where the equivalent needed an explicit AnalysisTemplate AND
#   progressDeadlineAbort, because steps advance on a timer by default.

_flagger_ns=demo-flagger

# Kill any error traffic left over from a previous part or a previous run.
#
# This is not tidiness. request-success-rate is computed from a RATE over the
# last minute of nginx counters, and those counters are namespace-wide -- so a
# `hey ... /status/500` still running from part 2 makes part 1 fail on the next
# invocation, with a perfectly good release and no visible cause. Measured:
# "success rate 36.89% < 99%" while every manual curl returned 200, because a
# `hey -z 3m` from the previous run had 90 seconds left to live.
_flagger_quiet() {
  kubectl -n "$_flagger_ns" exec deploy/flagger-loadtester -- \
    sh -c 'pkill -f "status/500" || true' >/dev/null 2>&1
  # Let the 1m rate window drain before measuring anything.
  sleep 65
}

_flagger_status() {
  kubectl -n "$_flagger_ns" get canary podinfo \
    -o jsonpath='{.status.phase}/{.status.canaryWeight}/{.status.failedChecks}' 2>/dev/null
}

scenario_apply() {
  [[ "$CTL" == "flux" ]] || { echo "    (Flagger only -- see 06 for the Argo Rollouts side)"; return 0; }
  kubectl -n "$_flagger_ns" get canary podinfo >/dev/null 2>&1 || {
    echo "    canary not installed; kubectl apply -f gitops/progressive/flagger/"; return 1; }

  echo "    Flagger's rewrite of your topology:"
  kubectl -n "$_flagger_ns" get deploy -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas' --no-headers | sed 's/^/      /'
  echo "      ^ podinfo at 0 is CORRECT. podinfo-primary is what serves."
  echo
  # Real, published tags. 6.7.2 and 6.7.3 were used first and DO NOT EXIST --
  # podinfo's releases jump from 6.7.x to 6.9.x. Flagger then reported
  #   "canary deployment not ready: 0 of 2 updated replicas are available"
  # and eventually "Canary failed! Scaling down", which looks exactly like a
  # metric-driven rollback and is nothing of the sort. Check the tag exists
  # before concluding a controller judged anything.
  echo "    clearing any error traffic left from a previous run (1m rate window)"
  _flagger_quiet
  echo "    part 1: a GOOD release -- expect progressing -> promoting -> succeeded"
  kubectl -n "$_flagger_ns" set image deploy/podinfo \
    podinfo=ghcr.io/stefanprodan/podinfo:6.9.4 2>&1 | sed 's/^/      /'
}

scenario_observe() {
  [[ "$CTL" == "flux" ]] || return 0
  local st
  for i in $(seq 1 28); do
    sleep 15
    st=$(_flagger_status)
    printf "    t+%-4ss phase/weight/failed = %s\n" "$((i*15))" "${st:-?}"
    case "${st%%/*}" in Succeeded|Failed) break ;; esac
  done

  echo
  echo "    part 2: a BAD release -- 500s injected into the canary's traffic"
  echo "    (the loadtester hits /status/500 on podinfo-canary, so"
  echo "     request-success-rate drops below the 99% threshold)"
  kubectl -n "$_flagger_ns" set image deploy/podinfo \
    podinfo=ghcr.io/stefanprodan/podinfo:6.10.2 2>&1 | sed 's/^/      /'
  sleep 30
  # Fire the error traffic from inside the loadtester, at the CANARY service --
  # hitting the stable service would prove nothing.
  local lt
  lt=$(kubectl -n "$_flagger_ns" get pod -l app=loadtester -o name | head -1)
  # Through the INGRESS with the canary Host header, not straight at the
  # Service. request-success-rate is computed from nginx's own counters, so a
  # request that bypasses nginx is invisible to the metric no matter how many
  # 500s it produces.
  kubectl -n "$_flagger_ns" exec "$lt" -- \
    hey -z 3m -c 2 -q 10 -host podinfo.local \
    "http://ingress-nginx-controller.ingress-nginx/status/500" >/dev/null 2>&1 &

  for i in $(seq 1 28); do
    sleep 15
    st=$(_flagger_status)
    printf "    t+%-4ss phase/weight/failed = %s\n" "$((i*15))" "${st:-?}"
    case "${st%%/*}" in Succeeded|Failed) break ;; esac
  done

  echo
  kubectl -n "$_flagger_ns" describe canary podinfo | grep -A12 '^Events:' | sed 's/^/      /'
  echo
  echo "    -> 'Failed' with rising failedChecks is Flagger deciding on its own."
  echo "    -> No AnalysisTemplate was written for this. The metrics ARE the gate."
}

scenario_reset() {
  [[ "$CTL" == "flux" ]] || return 0
  # Kill the error traffic FIRST. Leaving it running is what made a later good
  # release look broken.
  kubectl -n "$_flagger_ns" exec deploy/flagger-loadtester -- \
    sh -c 'pkill -f "status/500" || true' >/dev/null 2>&1
  kubectl -n "$_flagger_ns" set image deploy/podinfo \
    podinfo=ghcr.io/stefanprodan/podinfo:6.7.1 >/dev/null 2>&1
  return 0
}
