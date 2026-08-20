# QUESTION: Can Flux install and report on ITSELF declaratively, and what does that buy?
# EXPECT: Yes. And the interesting part is what the operator does BEFORE you hand over.
#
# `flux install` is imperative: a CLI on somebody's laptop renders manifests and
# applies them. Nothing in the cluster records which version was requested, and
# upgrading means finding the person with the right CLI version. An odd shape
# for a tool whose entire pitch is "the cluster matches git".
#
# MEASURED on EKS v1.33, flux-operator v0.58.1 adopting a live `flux install`:
#   FluxInstance Ready in 12s, ReconciliationSucceeded
#   revision v2.9.4@sha256:d2a9b010e5da...
#   both Kustomizations still Applied revision main@sha1:1a849382 throughout
#   the kustomize patch landed: source-controller requests 20m/64Mi
#
# The part worth knowing before you try it: installing the operator does NOT
# take over an existing flux-system. Until a FluxInstance exists it only
# OBSERVES, publishing a FluxReport that inventories whatever is running --
# including a plain `flux install`, and including Argo-CD-adjacent things it
# does not manage. That makes it useful as read-only observability first.

scenario_apply() {
  [[ "$CTL" == "flux" ]] || { echo "    (Flux side only)"; return 0; }
  kubectl -n flux-system get deploy flux-operator >/dev/null 2>&1 || {
    echo "    not installed: ./scripts/gitops-addons.sh flux-operator"; return 1; }
  echo "    flux-operator is running"
}

scenario_observe() {
  [[ "$CTL" == "flux" ]] || return 0

  echo
  echo "    [1] FluxReport -- the OBSERVE-only half, present with or without a FluxInstance:"
  kubectl -n flux-system get fluxreport flux \
    -o jsonpath='        distribution: {.spec.distribution.version} ({.spec.distribution.status}), entitlement: {.spec.distribution.entitlement}{"\n"}' 2>/dev/null
  echo "        reconcilers it found:"
  kubectl -n flux-system get fluxreport flux \
    -o jsonpath='{range .spec.reconcilers[*]}          {.kind}: running={.stats.running} failing={.stats.failing}{"\n"}{end}' 2>/dev/null \
    | grep -v 'running=0 failing=0'

  echo
  echo "    [2] FluxInstance -- the DECLARATIVE INSTALL half:"
  kubectl -n flux-system get fluxinstance flux \
    -o jsonpath='        ready={.status.conditions[?(@.type=="Ready")].status} reason={.status.conditions[?(@.type=="Ready")].reason}{"\n"}        revision={.status.lastAppliedRevision}{"\n"}' 2>/dev/null \
    || echo "        (none -- the operator is only observing)"
  echo "        did its kustomize patch reach the controllers?"
  kubectl -n flux-system get deploy source-controller \
    -o jsonpath='          source-controller requests={.spec.template.spec.containers[0].resources.requests}{"\n"}'

  echo
  echo "    [3] did the handover disturb anything?"
  flux get kustomizations 2>/dev/null | tail -n +2 | sed 's/^/        /'

  echo
  echo "    [4] ResourceSet -- Flux's answer to Argo CD's PullRequest generator:"
  kubectl -n flux-system get resourcesetinputprovider pr-envs \
    -o jsonpath='        provider ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}' 2>/dev/null
  kubectl -n flux-system get resourceset pr-envs \
    -o jsonpath='        resourceset ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}' 2>/dev/null
  local n
  n=$(kubectl get ns -l preview=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "        preview namespaces currently rendered: $n"
  echo "        (0 with no open PR carrying the 'preview' label -- an empty input"
  echo "         list renders an empty set, which is the correct answer and looks"
  echo "         identical to a broken provider. Check the provider's Ready above.)"

  echo
  echo "    [5] the web UI, which is the thing Flux is usually said not to have:"
  echo "        kubectl -n flux-system port-forward svc/flux-operator 9080:9080"
  kubectl -n flux-system get svc flux-operator \
    -o jsonpath='        ports={range .spec.ports[*]}{.name}:{.port} {end}{"\n"}' 2>/dev/null
  echo "        -> serves HTTP 200, <title>Flux Status</title>. AGPL-3.0 licensed,"
  echo "           which is a procurement question, not a technical one."

  echo
  echo "    -> the comparison to make out loud: Argo CD ships a UI and installs"
  echo "       imperatively; Flux installs declaratively and gets its UI from a"
  echo "       separate, differently-licensed operator."
}

scenario_reset() { return 0; }
