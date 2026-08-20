# QUESTION: Argo CD and Flux both "do Helm". Do they do the same thing?
# EXPECT: No, in two separate ways -- who runs Helm, and whether drift is corrected.
#
# FINDING 1 -- only one of them actually runs Helm.
#
#   Flux     helm-controller runs a real `helm upgrade --install`. There is a
#            release, `helm list` shows it, and sh.helm.release.v1.* Secrets
#            exist. `helm rollback` and `helm history` work.
#   Argo CD  runs `helm template` and applies the YAML. NO release, NO release
#            Secret, `helm list` is empty. Helm hooks work (Argo CD implements
#            them); `helm rollback` does not exist -- rollback means syncing to
#            an earlier git revision, which is a different guarantee.
#
#   MEASURED: release Secrets in the namespace -- Flux 1, Argo CD 0.
#
# FINDING 2 -- and this one is the operationally dangerous one.
#
#   Argo CD's selfHeal reverts hand-made changes to chart-owned objects.
#   Flux's HelmRelease DOES NOT, by default:
#
#     spec.driftDetection.mode  ->  "If not explicitly set, it defaults to
#                                    DiffModeDisabled."
#
#   MEASURED, `kubectl scale --replicas=5` on the chart's Deployment:
#     Argo CD                      back to 2 within 10s
#     Flux, mode unset (default)   still 5 after 180s, Ready=True throughout
#     Flux, mode=enabled           corrected -- but only on the next reconcile
#
#   The last line is the second half of the finding. Flux corrects drift on its
#   INTERVAL; Argo CD's selfHeal is event-driven. At the chart's default 5m
#   interval a hand-edit survives up to five minutes with everything green.
#   gitops/helm/flux/podinfo.yaml sets interval: 1m so this is observable, and
#   1m is still a poll.
#
#   That last clause is the trap. Flux is not broken and not lagging -- it
#   reconciles the RELEASE, and the release has not changed. "Ready" means "my
#   last helm upgrade succeeded", not "the cluster matches the chart". A Flux
#   HelmRelease without driftDetection is not self-healing, and its status will
#   never tell you.
#
# This scenario measures the default, then turns drift detection on and
# measures again.

_ns_for() { [[ "$1" == "argocd" ]] && echo demo-helm-argocd || echo demo-helm-flux; }
# Helm's fullname template includes the release name, and the release name is
# the Argo CD Application name -- so the Deployment is demo-helm-argocd-podinfo
# on one side and plain podinfo on the other. Resolve it, do not assume it.
_deploy_for() {
  kubectl -n "$(_ns_for "$1")" get deploy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

_replicas() { kubectl -n "$1" get deploy "$2" -o jsonpath='{.spec.replicas}' 2>/dev/null; }

# Scale to 5 and report how long it takes to come back, or that it does not.
_drift_test() {
  local ns="$1" dep="$2" label="$3" i r
  kubectl -n "$ns" scale "deploy/$dep" --replicas=5 2>&1 | sed 's/^/        /'
  for i in $(seq 1 18); do
    sleep 10
    r=$(_replicas "$ns" "$dep")
    printf "        t+%-4ss replicas=%s\n" "$((i*10))" "${r:-?}"
    if [[ "$r" == "2" ]]; then
      echo "        -> $label CORRECTED the drift after ~$((i*10))s"
      return 0
    fi
  done
  echo "        -> $label did NOT correct the drift in 180s (still $r)"
  return 1
}

scenario_apply() {
  local ns dep
  ns=$(_ns_for "$CTL"); dep=$(_deploy_for "$CTL")
  [[ -n "$dep" ]] || { echo "    no chart workload in $ns -- apply gitops/helm/$CTL/ first"; return 1; }
  echo "    chart workload: $ns/$dep"
}

scenario_observe() {
  local ns dep
  ns=$(_ns_for "$CTL"); dep=$(_deploy_for "$CTL")
  [[ -n "$dep" ]] || return 1

  echo
  echo "    FINDING 1 -- does Helm think it owns a release here?"
  if [[ -n "$(helm list -n "$ns" --short 2>/dev/null)" ]]; then
    helm list -n "$ns" 2>/dev/null | sed 's/^/      /'
  else
    echo "      (none -- helm list is empty)"
  fi
  echo "      sh.helm.release.v1.* Secrets: $(kubectl -n "$ns" get secret --no-headers 2>/dev/null | grep -c 'helm.release')"

  echo
  echo "    who reports on it, and what the report MEANS:"
  if [[ "$CTL" == "argocd" ]]; then
    kubectl -n argocd get app demo-helm-argocd \
      -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' --no-headers 2>/dev/null | sed 's/^/      /'
    echo "      Sync compares the LIVE CLUSTER to the rendered chart."
  else
    kubectl -n demo-helm-flux get helmrelease podinfo \
      -o custom-columns='HR:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,VER:.status.history[0].chartVersion' --no-headers 2>/dev/null | sed 's/^/      /'
    echo "      Ready reports on the last HELM UPGRADE, not on the live objects."
  fi

  echo
  echo "    FINDING 2 -- drift, at the default settings:"
  if [[ "$CTL" == "flux" ]]; then
    echo "      spec.driftDetection.mode = $(kubectl -n demo-helm-flux get helmrelease podinfo -o jsonpath='{.spec.driftDetection.mode}' 2>/dev/null || echo '<unset>') (default: disabled)"
  fi
  _drift_test "$ns" "$dep" "$CTL" || true

  # Second measurement, Flux only: the same drift with detection turned OFF,
  # which is the shipped default and therefore what most clusters are doing.
  if [[ "$CTL" == "flux" ]]; then
    echo
    echo "    now with driftDetection removed -- the DEFAULT, and the same test:"
    kubectl -n demo-helm-flux patch helmrelease podinfo --type=json \
      -p='[{"op":"remove","path":"/spec/driftDetection"}]' 2>&1 | sed 's/^/        /'
    flux reconcile helmrelease podinfo -n demo-helm-flux >/dev/null 2>&1
    sleep 10
    _drift_test "$ns" "$dep" "flux (driftDetection unset = default)" || true
    echo
    echo "      HelmRelease status while the cluster does NOT match the chart:"
    kubectl -n demo-helm-flux get helmrelease podinfo \
      -o jsonpath='        Ready={.status.conditions[?(@.type=="Ready")].status} reason={.status.conditions[?(@.type=="Ready")].reason}{"\n"}'
    echo "      -> green, and wrong. That is the whole point: Ready means the last"
    echo "         helm upgrade succeeded, not that the cluster matches the chart."
    # put it back the way git has it
    kubectl -n demo-helm-flux patch helmrelease podinfo --type=merge \
      -p '{"spec":{"driftDetection":{"mode":"enabled"}}}' >/dev/null 2>&1
  fi
}

scenario_reset() {
  local ns dep
  ns=$(_ns_for "$CTL"); dep=$(_deploy_for "$CTL")
  [[ -n "$dep" ]] && kubectl -n "$ns" scale "deploy/$dep" --replicas=2 >/dev/null 2>&1
  [[ "$CTL" == "flux" ]] && flux reconcile helmrelease podinfo -n demo-helm-flux >/dev/null 2>&1
  return 0
}
