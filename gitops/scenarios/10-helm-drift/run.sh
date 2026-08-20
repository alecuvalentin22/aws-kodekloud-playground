# QUESTION: Argo CD and Flux both "do Helm". Do they do the same thing?
# EXPECT: No. Flux runs Helm. Argo CD runs `helm template` and applies the YAML.
#
# The tell is whether a Helm RELEASE exists. Helm stores release state in a
# Secret in the namespace; `helm list` reads those. If Argo CD were using Helm,
# its release would show up there.
#
# Why it matters beyond trivia:
#   - `helm rollback` works on the Flux side and does not exist on the Argo side
#   - a failed upgrade leaves a Flux HelmRelease in a remediated state with a
#     retry count; on the Argo side it is just an unhealthy Application
#   - Helm hooks run in both (Argo CD implements them itself); Helm's --atomic
#     and --wait have no Argo CD equivalent, sync waves cover part of the job
#   - Flux can take a semver RANGE and upgrade with no commit; Argo CD can too,
#     but then the git revision no longer determines the cluster

scenario_apply() {
  local ns
  if [[ "$CTL" == "argocd" ]]; then ns=demo-helm-argocd; else ns=demo-helm-flux; fi
  kubectl get ns "$ns" >/dev/null 2>&1 || {
    echo "    $ns missing -- apply gitops/helm/$CTL/ first"; return 1; }
  echo "    workload from the podinfo CHART in $ns:"
  kubectl -n "$ns" get deploy --no-headers 2>/dev/null | sed 's/^/      /'
}

scenario_observe() {
  local ns
  if [[ "$CTL" == "argocd" ]]; then ns=demo-helm-argocd; else ns=demo-helm-flux; fi

  echo
  echo "    does Helm think it owns a release here?"
  local rel
  rel=$(helm list -n "$ns" --short 2>/dev/null)
  if [[ -n "$rel" ]]; then
    helm list -n "$ns" 2>/dev/null | sed 's/^/      /'
    echo "      -> a real Helm release. helm rollback / helm history work."
  else
    echo "      (none)"
    echo "      -> no release secret, so Helm has no idea this exists."
  fi

  echo
  echo "    the release-storage Secrets Helm uses (sh.helm.release.v1.*):"
  local n; n=$(kubectl -n "$ns" get secret --no-headers 2>/dev/null | grep -c 'helm.release' || true)
  echo "      count: ${n:-0}"

  echo
  echo "    who reports on it:"
  if [[ "$CTL" == "argocd" ]]; then
    kubectl -n argocd get app demo-helm-argocd \
      -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' --no-headers 2>/dev/null | sed 's/^/      /'
  else
    kubectl -n demo-helm-flux get helmrelease podinfo \
      -o custom-columns='HR:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,REV:.status.lastAttemptedRevision' --no-headers 2>/dev/null | sed 's/^/      /'
  fi

  echo
  echo "    drift test -- scale the chart's Deployment by hand:"
  kubectl -n "$ns" scale deploy/podinfo --replicas=5 2>&1 | sed 's/^/      /'
  for i in $(seq 1 12); do
    sleep 15
    printf "      t+%-4ss replicas=%s\n" "$((i*15))" \
      "$(kubectl -n "$ns" get deploy podinfo -o jsonpath='{.spec.replicas}' 2>/dev/null)"
    [[ "$(kubectl -n "$ns" get deploy podinfo -o jsonpath='{.spec.replicas}' 2>/dev/null)" == "2" ]] && break
  done
  echo "      -> back to 2 means the chart's values, not the live object, are the truth"
}

scenario_reset() { return 0; }
