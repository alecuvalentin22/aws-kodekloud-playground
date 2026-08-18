# QUESTION: A release is broken (image does not exist). Does GitOps roll it back?
# EXPECT: No. Both controllers faithfully deploy the broken thing and keep it broken.
#
# This is the scenario that corrects the most common misconception about GitOps.
# Reconciliation guarantees the cluster MATCHES GIT. It says nothing about
# whether what is in git works. There is no health gate, no automatic revert,
# and selfHeal makes it worse -- it will keep re-applying the broken manifest.
#
# The saving grace is Kubernetes, not the GitOps controller: a Deployment's
# RollingUpdate will not scale down healthy old pods until new ones are Ready,
# so the SERVICE usually survives while the rollout hangs. That is maxUnavailable
# doing its job, and it is the entire safety net you get for free.
#
# Rolling back is a human action -- `git revert` -- unless you add Argo Rollouts
# or Flagger. See gitops/scenarios/README.md.

scenario_apply() {
  kubectl -n "$NS" set image deploy/podinfo podinfo=ghcr.io/stefanprodan/podinfo:0.0.0-does-not-exist 2>&1 | sed 's/^/    /'
}

scenario_observe() {
  for i in $(seq 1 8); do
    sleep 12
    local ready avail bad ctl
    ready=$(kubectl -n "$NS" get deploy podinfo -o jsonpath='{.status.readyReplicas}' 2>/dev/null); ready=${ready:-0}
    avail=$(kubectl -n "$NS" get deploy podinfo -o jsonpath='{.status.availableReplicas}' 2>/dev/null); avail=${avail:-0}
    bad=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -cE "ImagePullBackOff|ErrImagePull")
    if [[ "$CTL" == "argocd" ]]; then
      ctl=$(kubectl -n argocd get app demo-argocd -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
    else
      ctl=$(kubectl -n flux-system get kustomization apps -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
    fi
    printf "    t+%-3ss  controller=%-22s serving=%s broken_pods=%s\n" "$((i*12))" "$ctl" "$avail" "$bad"
  done
  echo "    -> the old pods are still serving; the new ones never start."
  echo "    -> nothing rolled back. Recovery is 'git revert', by a human."
}

scenario_reset() {
  if [[ "$CTL" == "flux" ]]; then
    flux reconcile kustomization apps --with-source >/dev/null 2>&1
  else
    kubectl -n argocd patch app demo-argocd --type=merge \
      -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' >/dev/null 2>&1
  fi
}
