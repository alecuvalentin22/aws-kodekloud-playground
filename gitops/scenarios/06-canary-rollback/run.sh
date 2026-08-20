# QUESTION: With a real traffic provider, does Argo Rollouts roll a bad release BACK, or just stop?
# EXPECT: Rolls back. Scenario 05 showed "capped at 25% but stuck" -- two things were missing.
#
# This scenario is the corrected twin of the earlier measurement. What changed:
#
#   1. trafficRouting.nginx  -> there is now a podinfo-canary Service pinned to
#      the canary ReplicaSet, so the AnalysisTemplate has something to analyse.
#      Previously it curled the ONE Service selecting all 4 pods and reported
#      Successful while a pod sat in ImagePullBackOff.
#   2. progressDeadlineAbort -> without it, hitting progressDeadlineSeconds only
#      MARKS the rollout Degraded. It does not abort. That is the whole reason
#      the earlier run capped the blast radius and then sat there.
#
# Runs on the Argo side only. Flagger is scenario 07.

scenario_apply() {
  [[ "$CTL" == "argocd" ]] || { echo "    (Argo Rollouts only -- see 07 for the Flux side)"; return 0; }
  local ns=demo-rollouts-nginx
  kubectl -n "$ns" get rollout podinfo >/dev/null 2>&1 || {
    echo "    rollout not installed; kubectl apply -f gitops/progressive/rollouts-nginx/" ; return 1; }

  echo "    baseline:"
  kubectl -n "$ns" get rollout podinfo \
    -o jsonpath='      revision={.status.currentPodHash} phase={.status.phase}{"\n"}'

  echo "    shipping a broken image (tag does not exist)"
  # Not suppressed. Scenario 02 hid the output of the thing it was testing and
  # reported Healthy for 96 seconds.
  kubectl -n "$ns" set image rollout/podinfo \
    podinfo=ghcr.io/stefanprodan/podinfo:0.0.0-broken 2>&1 | sed 's/^/      /'
  SCEN06_START=$(date +%s)
}

scenario_observe() {
  [[ "$CTL" == "argocd" ]] || return 0
  local ns=demo-rollouts-nginx
  local phase msg weight canary_ing analysis
  for i in $(seq 1 20); do
    sleep 10
    phase=$(kubectl -n "$ns" get rollout podinfo -o jsonpath='{.status.phase}' 2>/dev/null)
    msg=$(kubectl -n "$ns" get rollout podinfo -o jsonpath='{.status.message}' 2>/dev/null | cut -c1-32)
    # The canary Ingress is created by the controller, not by us. Its weight
    # annotation is the ACTUAL traffic split -- read that, not the step number.
    weight=$(kubectl -n "$ns" get ingress podinfo-podinfo-canary-ingress \
      -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary-weight}' 2>/dev/null)
    analysis=$(kubectl -n "$ns" get analysisrun --no-headers 2>/dev/null | tail -1 | awk '{print $2}')
    printf "    t+%-3ss  phase=%-12s weight=%-4s analysis=%-12s %s\n" \
      "$((i*10))" "${phase:-?}" "${weight:-0}" "${analysis:-none}" "$msg"
    [[ "$phase" == "Degraded" || "$phase" == "Healthy" ]] && [[ $i -gt 3 ]] && break
  done

  echo
  echo "    what the pods actually are now:"
  kubectl -n "$ns" get pods -o custom-columns='NAME:.metadata.name,IMAGE:.spec.containers[0].image,STATUS:.status.phase' --no-headers | sed 's/^/      /'
  echo
  echo "    -> Degraded + weight back to 0 + old image serving == aborted and rolled back"
  echo "    -> compare scenario 05, where the same break left it Progressing forever"
}

scenario_reset() {
  [[ "$CTL" == "argocd" ]] || return 0
  kubectl argo rollouts undo podinfo -n demo-rollouts-nginx >/dev/null 2>&1
  kubectl -n demo-rollouts-nginx set image rollout/podinfo \
    podinfo=ghcr.io/stefanprodan/podinfo:6.7.1 >/dev/null 2>&1
  return 0
}
