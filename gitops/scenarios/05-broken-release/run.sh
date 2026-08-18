# QUESTION: A release is broken (image tag does not exist). Does GitOps roll it back?
# EXPECT: No. Both deploy it faithfully and keep it broken. Recovery is a human git revert.
#
# MEASURED on EKS v1.33, broken image pushed to main:
#   argocd  serving=3 broken=1 for 105s, health=Progressing then Degraded
#   flux    serving=3 broken=1 for 105s, ReconciliationSucceeded
#   after `git revert` + reconcile: both recovered in 26s
#
# IMPORTANT: break it through GIT, not kubectl. The first version of this
# scenario used `kubectl set image`, and Argo CD's selfHeal reverted it within
# 12s -- so it measured selfHeal, not a bad release. Flux appeared "worse" purely
# because its interval had not elapsed. Two very different findings that look
# identical if you are not careful about how the break is introduced.

scenario_apply() {
  echo "    NOTE: run this properly by pushing a broken image to git, e.g."
  echo "      sed -i '' 's|podinfo:6.7.1|podinfo:0.0.0-broken|' gitops/app/base/deployment.yaml"
  echo "      git commit -am 'break' && git push && git revert HEAD && git push"
  echo "    Patching locally instead only tests selfHeal -- see the header."
  kubectl -n "$NS" set image deploy/podinfo podinfo=ghcr.io/stefanprodan/podinfo:0.0.0-broken 2>&1 | sed 's/^/    /'
}

scenario_observe() {
  for i in $(seq 1 6); do
    sleep 12
    local avail bad ctl
    avail=$(kubectl -n "$NS" get deploy podinfo -o jsonpath='{.status.availableReplicas}' 2>/dev/null); avail=${avail:-0}
    bad=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -cE "ImagePull|ErrImage")
    if [[ "$CTL" == "argocd" ]]; then
      ctl=$(kubectl -n argocd get app demo-argocd -o jsonpath='{.status.health.status}' 2>/dev/null)
    else
      ctl=$(kubectl -n flux-system get kustomization apps -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
    fi
    printf "    t+%-3ss  controller=%-22s serving=%s broken=%s\n" "$((i*12))" "$ctl" "$avail" "$bad"
  done
  echo "    -> old pods keep serving (Kubernetes maxUnavailable, NOT the GitOps controller)"
  echo "    -> nothing rolled back automatically"
}

scenario_reset() {
  [[ "$CTL" == "flux" ]] && flux reconcile kustomization apps --with-source >/dev/null 2>&1
  kubectl -n argocd patch app demo-argocd --type=merge \
    -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' >/dev/null 2>&1
  return 0
}
