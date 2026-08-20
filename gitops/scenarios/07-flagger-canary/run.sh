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

_flagger_ns=demo-flagger

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
  echo "    part 1: a GOOD release -- expect progressing -> promoting -> succeeded"
  kubectl -n "$_flagger_ns" set image deploy/podinfo \
    podinfo=ghcr.io/stefanprodan/podinfo:6.7.2 2>&1 | sed 's/^/      /'
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
    podinfo=ghcr.io/stefanprodan/podinfo:6.7.3 2>&1 | sed 's/^/      /'
  sleep 30
  # Fire the error traffic from inside the loadtester, at the CANARY service --
  # hitting the stable service would prove nothing.
  local lt
  lt=$(kubectl -n "$_flagger_ns" get pod -l app=flagger-loadtester -o name | head -1)
  kubectl -n "$_flagger_ns" exec "$lt" -- \
    hey -z 3m -c 2 -q 10 "http://podinfo-canary.$_flagger_ns:9898/status/500" >/dev/null 2>&1 &

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
  kubectl -n "$_flagger_ns" set image deploy/podinfo \
    podinfo=ghcr.io/stefanprodan/podinfo:6.7.1 >/dev/null 2>&1
  return 0
}
