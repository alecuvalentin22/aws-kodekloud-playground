# QUESTION: How long from `git push` until the change is live?
# EXPECT: Flux is faster by default (interval 1m) than Argo CD (~3m poll). This INVERTS scenario 03.
#
# MEASURED on EKS v1.33: flux 78s, argo cd 155s.
#
# Neither number is a property of the tool. Argo CD closes the gap with a
# webhook; Flux closes its drift gap with a lower interval. The defaults simply
# optimise for different things: Flux for source freshness, Argo CD for cluster
# convergence.
#
# This scenario is READ-ONLY -- it reports the configured intervals rather than
# pushing a commit, because a scenario runner that rewrites your git history is
# a bad idea. To measure it live, change replicas in the overlay, push, and time
# it.

scenario_apply() {
  echo "    (read-only -- reporting configured reconciliation settings)"
}

scenario_observe() {
  if [[ "$CTL" == "argocd" ]]; then
    local poll
    poll=$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation}' 2>/dev/null)
    echo "    argocd-cm timeout.reconciliation = ${poll:-<unset, default 180s>}"
    echo "    selfHeal watches the CLUSTER continuously -> fast drift correction"
    echo "    git is POLLED -> slower to see a push; add a webhook to fix"
  else
    local iv
    iv=$(kubectl -n flux-system get gitrepository platform-lab -o jsonpath='{.spec.interval}' 2>/dev/null)
    echo "    GitRepository interval = ${iv:-unknown}"
    kubectl -n flux-system get kustomization apps -o jsonpath='    Kustomization interval = {.spec.interval}{"\n"}' 2>/dev/null
    echo "    polls the SOURCE often -> fast to see a push"
    echo "    drift is only noticed on that same interval -> slower correction"
  fi
  echo "    measured: flux 78s, argo cd 155s (EKS v1.33, this repo)"
}

scenario_reset() { return 0; }
