# QUESTION: Where does each controller surface a manifest that the API server rejects?
# EXPECT: Both fail, but you look in different places -- Application health vs Kustomization conditions.
#
# The break: patch the live Deployment with an impossible resource request so
# the ReplicaSet cannot schedule. Then watch whether the controller notices that
# the desired state is unreachable, and where it says so.

scenario_apply() {
  # CPU, not memory. The base sets a memory LIMIT of 128Mi, and the API server
  # rejects any request that exceeds its own limit:
  #
  #   Invalid value: "900Gi": must be less than or equal to memory limit of 128Mi
  #
  # The first version of this scenario patched memory and suppressed stderr, so
  # the patch was refused, nothing broke, and the scenario reported "Healthy"
  # for 96 seconds on both controllers -- a completely convincing non-result.
  #
  # NEVER suppress the output of the thing whose failure you are testing for.
  # The base deliberately sets no CPU limit, so a huge CPU request is accepted
  # by the API server and then simply cannot be scheduled -- which is the state
  # we actually want to observe.
  local out
  out=$(kubectl -n "$NS" patch deploy podinfo --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"500"}]' 2>&1)
  echo "    $out"
  echo "    patched podinfo to request 500 CPUs (accepted, but unschedulable)"
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
