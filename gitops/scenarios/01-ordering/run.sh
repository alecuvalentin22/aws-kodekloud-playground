# QUESTION: If a dependency is broken, does the controller still deploy what depends on it?
# EXPECT: Flux refuses to start `apps` (dependsOn + wait). Argo CD has no equivalent unless you add sync-waves.
#
# The break: delete the namespace the app is deployed into, WITHOUT changing git.
# For Flux that makes the `infrastructure` Kustomization the thing that must
# re-create it, and `apps` dependsOn it. For Argo CD the namespace comes from
# CreateNamespace=true inside the same Application -- there is no ordering
# boundary at all, which is the point.

scenario_apply() {
  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
  echo "    deleted namespace $NS (dependency broken, git unchanged)"
}

scenario_observe() {
  for i in $(seq 1 10); do
    sleep 12
    local phase pods
    pods=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$CTL" == "argocd" ]]; then
      phase=$(kubectl -n argocd get app demo-argocd -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
    else
      phase=$(kubectl -n flux-system get kustomization apps -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      phase="ready=$phase"
    fi
    printf "    t+%-3ss  status=%-22s pods=%s\n" "$((i*12))" "$phase" "$pods"
    [[ "$pods" -gt 0 ]] && { echo "    -> recovered"; return; }
  done
  echo "    -> did NOT recover within 120s"
}

scenario_reset() {
  if [[ "$CTL" == "flux" ]]; then
    flux reconcile kustomization infrastructure --with-source >/dev/null 2>&1
    flux reconcile kustomization apps >/dev/null 2>&1
  else
    kubectl -n argocd patch app demo-argocd --type=merge \
      -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' >/dev/null 2>&1
  fi
}
