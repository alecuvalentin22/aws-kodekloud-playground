# QUESTION: Where does each controller surface a manifest that the API server rejects?
# EXPECT: Both fail, but you look in different places -- Application health vs Kustomization conditions.
#
# The break: patch the live Deployment with an impossible resource request so
# the ReplicaSet cannot schedule. Then watch whether the controller notices that
# the desired state is unreachable, and where it says so.

scenario_apply() {
  kubectl -n "$NS" patch deploy podinfo --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"900Gi"}]' \
    >/dev/null 2>&1
  echo "    patched podinfo to request 900Gi (unschedulable)"
}

scenario_observe() {
  for i in $(seq 1 8); do
    sleep 12
    local ready pending msg
    ready=$(kubectl -n "$NS" get deploy podinfo -o jsonpath='{.status.readyReplicas}' 2>/dev/null); ready=${ready:-0}
    pending=$(kubectl -n "$NS" get pods --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$CTL" == "argocd" ]]; then
      msg=$(kubectl -n argocd get app demo-argocd -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
    else
      msg=$(kubectl -n flux-system get kustomization apps -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
    fi
    printf "    t+%-3ss  controller=%-20s ready=%s pending=%s\n" "$((i*12))" "$msg" "$ready" "$pending"
  done
  echo "    where to look:"
  [[ "$CTL" == "argocd" ]] \
    && echo "      kubectl -n argocd get app demo-argocd -o jsonpath='{.status.health}'" \
    || echo "      kubectl -n flux-system get kustomization apps -o jsonpath='{.status.conditions}'"
}

scenario_reset() {
  if [[ "$CTL" == "flux" ]]; then
    flux reconcile kustomization apps --with-source >/dev/null 2>&1
  else
    kubectl -n argocd patch app demo-argocd --type=merge \
      -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' >/dev/null 2>&1
  fi
}
