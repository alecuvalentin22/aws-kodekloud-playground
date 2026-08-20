# QUESTION: Can you route a NAMED COHORT to a new version rather than a percentage?
# EXPECT: Yes -- but not with Argo Rollouts on nginx. The routing is an ingress feature.
#
# Two findings, and the first one is the reason this scenario is not a Rollout:
#
#   Argo Rollouts `setHeaderRoute` DOES NOT SUPPORT NGINX. The Rollout is
#   rejected at admission and goes to Degraded with zero replicas:
#
#     spec.strategy.steps[1].setHeaderRoute: Invalid value: {...}:
#     SetHeaderRoute requires TrafficRouting, supports Istio and ALB and Apisix
#
#   Note `trafficRouting.nginx` IS supported for WEIGHTED canaries -- scenario
#   06 uses it. It is header and mirror routing specifically that nginx is
#   excluded from. ALB would work; the AWS Load Balancer Controller needs IRSA
#   and this playground restricts iam:CreateRole to three exact role names.
#
#   The header routing itself needs no progressive-delivery controller at all.
#   Two Ingresses, same host and path, one annotated canary-by-header. Where
#   setHeaderRoute IS supported it writes these same annotations for you.
#
# MEASURED on EKS v1.33, ingress-nginx 4.15.1 -- 20 requests each:
#
#   no header                      20 variant-A    0 variant-B
#   X-Cohort: beta                  0 variant-A   20 variant-B
#   X-Cohort: control               20 variant-A    0 variant-B
#   Cookie: ab-cohort=always        0 variant-A   20 variant-B
#
# Clean in both directions, at canary-weight 0 throughout.
#
# What gets measured: that the cohort reaches B and that ordinary traffic
# NEVER does. The second half is the one people forget to check, and it is what
# makes this an A/B test rather than a canary -- canary-weight is 0 throughout.

_ab_ns=demo-ab
_ab_url() {
  echo "http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}'):30090"
}

# 20 requests, tally which variant answered.
_tally() {
  local url="$1"; shift
  local i
  for i in $(seq 1 20); do
    curl -s --max-time 5 -H 'Host: ab.local' "$@" "$url/" 2>/dev/null \
      | grep -o 'variant-[AB]' || echo "no-answer"
  done | sort | uniq -c | sed 's/^/        /'
}

scenario_apply() {
  [[ "$CTL" == "argocd" ]] || { echo "    (ingress-level; runs once, not per controller)"; return 0; }
  kubectl -n "$_ab_ns" get ingress podinfo-cohort >/dev/null 2>&1 || {
    echo "    not installed: kubectl apply -f gitops/progressive/ab-testing/"; return 1; }
  kubectl -n "$_ab_ns" rollout status deploy/podinfo-a --timeout=180s | sed 's/^/    /'
  kubectl -n "$_ab_ns" rollout status deploy/podinfo-b --timeout=180s | sed 's/^/    /'
}

scenario_observe() {
  [[ "$CTL" == "argocd" ]] || return 0
  local url; url=$(_ab_url)

  echo
  echo "    the two Ingresses -- note the identical host and path:"
  kubectl -n "$_ab_ns" get ingress -o custom-columns='NAME:.metadata.name,HOST:.spec.rules[0].host,SVC:.spec.rules[0].http.paths[0].backend.service.name,CANARY:.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary' --no-headers | sed 's/^/      /'
  echo
  echo "    cohort selection:"
  kubectl -n "$_ab_ns" get ingress podinfo-cohort -o jsonpath='      header={.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary-by-header}={.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary-by-header-value} cookie={.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary-by-cookie} weight={.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary-weight}{"\n"}'

  echo
  echo "      [1] 20 requests, NO header -- weight is 0, so ALL must be A:"
  _tally "$url"

  echo
  echo "      [2] 20 requests with X-Cohort: beta -- ALL must be B:"
  _tally "$url" -H 'X-Cohort: beta'

  echo
  echo "      [3] 20 requests with X-Cohort: control -- header present but not"
  echo "          matching. Must fall through to A, not to B:"
  _tally "$url" -H 'X-Cohort: control'

  echo
  echo "      [4] 20 requests with Cookie: ab-cohort=always -- ALL must be B."
  echo "          This is the one that gives an experiment a stable population:"
  _tally "$url" -H 'Cookie: ab-cohort=always'

  echo
  echo "    -> a clean 20/0 in BOTH directions is the property a canary cannot give"
  echo "    -> [3] matters: a non-matching value must not leak into the cohort"
}

scenario_reset() { return 0; }
