# QUESTION: How fast does each controller undo a manual kubectl change?
# EXPECT: Argo CD reverts in seconds via selfHeal. Flux waits for its interval.
#
# MEASURED on EKS v1.33: argocd <10s, flux still drifted at 90s.
# This is the headline difference and the easiest one to show a sceptic.

scenario_apply() {
  kubectl -n "$NS" scale deploy/podinfo --replicas=7 >/dev/null 2>&1
  echo "    scaled podinfo to 7 by hand (git still says 3)"
}

scenario_observe() {
  local want
  want=$(kubectl -n "$NS" get deploy podinfo -o jsonpath='{.spec.replicas}' 2>/dev/null)
  for i in $(seq 1 8); do
    sleep 10
    local n; n=$(kubectl -n "$NS" get deploy podinfo -o jsonpath='{.spec.replicas}' 2>/dev/null)
    printf "    t+%-3ss  replicas=%s\n" "$((i*10))" "$n"
    [[ "$n" != "7" ]] && { echo "    -> reverted after ~$((i*10))s"; return; }
  done
  echo "    -> still drifted at 80s (expected for Flux; force it with 'flux reconcile')"
}

scenario_reset() {
  [[ "$CTL" == "flux" ]] && flux reconcile kustomization apps >/dev/null 2>&1
  return 0
}
