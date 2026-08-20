# QUESTION: Can you route a NAMED COHORT to a new version rather than a percentage?
# EXPECT: Yes, with setHeaderRoute. And the same request must get the same answer every time.
#
# The distinction being tested is not cosmetic. A canary is a random sample: the
# same user can hit v1 and then v2 on the next click. That is fine when the
# question is "is v2 crashing" and useless when the question is "does v2 convert
# better" -- because you cannot attribute a conversion to a variant the user was
# only sometimes in.
#
# So this scenario proves TWO things, and the second is the one people forget:
#   1. the header reaches the canary at all
#   2. no-header traffic NEVER reaches it -- weight stays 0

_ab_ns=demo-ab
_ab_url() { echo "http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}'):30090"; }

scenario_apply() {
  [[ "$CTL" == "argocd" ]] || { echo "    (Argo Rollouts only)"; return 0; }
  kubectl -n "$_ab_ns" get rollout podinfo >/dev/null 2>&1 || {
    echo "    not installed; kubectl apply -f gitops/progressive/ab-testing/"; return 1; }

  echo "    shipping variant B"
  kubectl -n "$_ab_ns" patch rollout podinfo --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"variant-B"}
  ]' 2>&1 | sed 's/^/      /'
}

scenario_observe() {
  [[ "$CTL" == "argocd" ]] || return 0
  local url; url=$(_ab_url)

  echo "    waiting for the header route to be programmed..."
  for i in $(seq 1 20); do
    kubectl -n "$_ab_ns" get ingress 2>/dev/null | grep -q 'header' && break
    sleep 10
  done

  echo
  echo "    ingresses (the second one is created BY the controller):"
  kubectl -n "$_ab_ns" get ingress --no-headers | sed 's/^/      /'
  echo
  echo "    the annotations that implement it:"
  for ing in $(kubectl -n "$_ab_ns" get ingress -o name | grep -v 'ingress/podinfo$'); do
    kubectl -n "$_ab_ns" get "$ing" -o jsonpath='{.metadata.name}: {.metadata.annotations}{"\n"}' \
      2>/dev/null | sed 's/^/      /'
  done

  echo
  echo "    20 requests with NO header (must all be A -- weight is 0):"
  for _ in $(seq 1 20); do
    curl -s -H 'Host: ab.local' --max-time 3 "$url/" 2>/dev/null | grep -o 'variant-[AB]' || echo "?"
  done | sort | uniq -c | sed 's/^/      /'

  echo
  echo "    20 requests WITH X-Cohort: beta (must all be B):"
  for _ in $(seq 1 20); do
    curl -s -H 'Host: ab.local' -H 'X-Cohort: beta' --max-time 3 "$url/" 2>/dev/null | grep -o 'variant-[AB]' || echo "?"
  done | sort | uniq -c | sed 's/^/      /'

  echo
  echo "    -> a clean 20/0 split BOTH ways is the property a canary cannot give you"
  echo "    -> the rollout is paused indefinitely; promote or abort ends the experiment:"
  echo "         kubectl argo rollouts promote podinfo -n $_ab_ns"
  echo "         kubectl argo rollouts abort   podinfo -n $_ab_ns"
}

scenario_reset() {
  [[ "$CTL" == "argocd" ]] || return 0
  kubectl argo rollouts abort podinfo -n "$_ab_ns" >/dev/null 2>&1
  kubectl -n "$_ab_ns" patch rollout podinfo --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"variant-A"}
  ]' >/dev/null 2>&1
  return 0
}
