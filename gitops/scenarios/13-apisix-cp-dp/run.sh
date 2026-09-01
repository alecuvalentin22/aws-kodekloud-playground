# QUESTION: APISIX has two sync hops. Break each. Which failure is SILENT?
# EXPECT: The control-plane one. The gateway serves stale config and reports healthy.
#
# THE ARCHITECTURE, and it is not the one most material describes.
#
# Every apisix-ingress-controller v1.x tutorial says the controller writes to
# etcd and the gateway watches it. Version 2.x does not do that. The controller
# runs an ADC sidecar and pushes through the ADMIN API:
#
#   ApisixRoute ──► controller + ADC ──► Admin API ──► APISIX ──► etcd ──► worker
#                   \_____ hop A ______/              \______ hop B _______/
#                     control plane                        data plane
#
# Still two independent hops, still failing differently, but hop A is an HTTP
# call rather than an etcd write. Anyone telling you to check the controller's
# etcd connection is debugging the previous major version.
#
# WHY THIS IS THE INTERESTING FAILURE. A gateway is the one component where
# "serving traffic correctly" and "serving the config you asked for" can diverge
# indefinitely without anything going red. Hop A breaks exactly that way: every
# probe passes, every dashboard is green, and the routes are whatever they were
# when the controller last managed to push.
#
# config.provider.syncPeriod is 1m by default, so hop A can SELF-HEAL within a
# minute of the controller returning. That is why this scenario measures how
# long the stale window lasts rather than just asserting that it exists.
#
# MEASURED on EKS 1.33, APISIX 3.18.0, apisix-ingress-controller 2.2.0:
#
#   HOP A -- controller scaled to 0, ApisixRoute repointed v1 -> v2
#     t+10s .. t+90s   CRD says demo-v2, gateway serves v1, ctl=0/0 gw=3/3
#                      Admin API still holds the OLD route
#     recovery         converged 53s after the controller came back
#     signal emitted   NONE. Gateway Ready, pods Ready, probes passing, no
#                      error in any log, nothing on any dashboard.
#
#   HOP B -- etcd scaled to 0 under a healthy gateway
#     t+10s .. t+40s   gateway KEEPS SERVING (serves=v2 throughout)
#     controller logs  loud and immediate:
#                        HTTP 500: AxiosError: Request failed with status 503
#                        failed to sync resources
#                        failed to sync 1 configs
#
# So the two hops fail in opposite directions:
#   A is silent and breaks CORRECTNESS  (serving the wrong config, quietly)
#   B is loud   and breaks CHANGE       (serving fine, cannot be updated)
#
# The operational conclusion is the interesting part: the alert people write is
# "is the gateway up", and it would have caught NEITHER. Both hops leave the
# gateway up and serving. The alert that catches hop A is
# "controller's last successful sync is older than N", and it is not a metric
# anything ships by default.

_ns=apisix
_demo=demo-apisix
_host=demo.apisix.local

_gw() {
  # Hit the gateway from inside the cluster, so the measurement does not depend
  # on a NodePort or a security group.
  kubectl -n "$_demo" run curl-$RANDOM --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.10.1 -- \
    curl -s --max-time 5 -H "Host: $_host" "http://apisix-gateway.$_ns:80/" 2>/dev/null \
    | grep -o 'v[12]' | head -1
}

# What the gateway itself believes its routes are, read from the Admin API.
# This is the ground truth that the CRD is supposed to converge to.
_routes_in_gateway() {
  local key
  key=$(kubectl -n "$_ns" get secret apisix-admin -o jsonpath='{.data.key}' 2>/dev/null | base64 -d)
  kubectl -n "$_ns" run adm-$RANDOM --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.10.1 -- \
    curl -s --max-time 5 -H "X-API-KEY: $key" \
    "http://apisix-admin.$_ns:9180/apisix/admin/routes" 2>/dev/null \
    | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    for it in d.get("list", d.get("node",{}).get("nodes",[])):
        v=it.get("value",it)
        ups=v.get("upstream",{}).get("nodes",{})
        print("      route", v.get("id","?"), "->", ups if isinstance(ups,dict) else ups)
except Exception as e:
    print("      (could not read Admin API:", e, ")")' 2>/dev/null
}

_ctl_status() {
  printf "ctl=%s/%s  gw=%s/%s" \
    "$(kubectl -n "$_ns" get deploy apisix-ingress-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)" \
    "$(kubectl -n "$_ns" get deploy apisix-ingress-controller -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)" \
    "$(kubectl -n "$_ns" get deploy apisix -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)" \
    "$(kubectl -n "$_ns" get deploy apisix -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
}

scenario_apply() {
  [[ "$CTL" == "argocd" ]] || { echo "    (gateway-level; runs once, not per GitOps controller)"; return 0; }
  kubectl -n "$_ns" get deploy apisix >/dev/null 2>&1 || {
    echo "    APISIX not installed -- run: make apisix"; return 1; }
  echo "    baseline: $(_ctl_status)"
  echo "    route currently serves: $(_gw)"
}

scenario_observe() {
  [[ "$CTL" == "argocd" ]] || return 0

  # ==========================================================================
  echo
  echo "    HOP A -- CONTROL PLANE. Kill the controller, then change the CRD."
  echo "    Nothing is wrong with the gateway. It simply stops being told."
  kubectl -n "$_ns" scale deploy/apisix-ingress-controller --replicas=0 2>&1 | sed 's/^/      /'
  sleep 15
  echo "      $(_ctl_status)"

  echo "      changing the ApisixRoute to point at v2 (the controller cannot see it)"
  kubectl -n "$_demo" patch apisixroute demo --type=json \
    -p='[{"op":"replace","path":"/spec/http/0/backends/0/serviceName","value":"demo-v2"}]' 2>&1 | sed 's/^/      /'

  echo "      what git/the CRD says: demo-v2"
  local i served
  for i in $(seq 1 9); do
    sleep 10
    served=$(_gw)
    printf "      t+%-3ss  CRD=demo-v2  gateway serves=%-4s  %s\n" \
      "$((i*10))" "${served:-?}" "$(_ctl_status)"
  done
  echo "      what the gateway actually holds:"
  _routes_in_gateway

  echo
  echo "      -> the gateway is Ready, its pods are Ready, its probes pass, and it"
  echo "         is serving configuration that no longer matches the cluster."
  echo "         NOTHING reports a problem. This is the silent failure."

  # ==========================================================================
  echo
  echo "    RECOVERY -- bring the controller back and time the convergence."
  local start conv
  start=$(date +%s)
  kubectl -n "$_ns" scale deploy/apisix-ingress-controller --replicas=1 2>&1 | sed 's/^/      /'
  conv=""
  for i in $(seq 1 24); do
    sleep 10
    served=$(_gw)
    printf "      t+%-3ss  gateway serves=%-4s  %s\n" "$((i*10))" "${served:-?}" "$(_ctl_status)"
    [[ "$served" == "v2" ]] && { conv=$(( $(date +%s) - start )); break; }
  done
  if [[ -n "$conv" ]]; then
    echo "      -> converged ${conv}s after the controller returned"
    echo "         (config.provider.syncPeriod is 1m -- a stall shorter than that"
    echo "          can heal before anyone notices it happened)"
  else
    echo "      -> did NOT converge within 240s; check the controller logs"
  fi

  # ==========================================================================
  echo
  echo "    HOP B -- DATA PLANE. etcd disrupted under a healthy gateway."
  echo "    Different failure: the gateway KEEPS SERVING, but cannot learn."
  kubectl -n "$_ns" scale statefulset/apisix-etcd --replicas=0 2>&1 | sed 's/^/      /'
  sleep 20
  echo "      etcd replicas: $(kubectl -n "$_ns" get statefulset apisix-etcd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  echo "      does the gateway still serve traffic with its config store gone?"
  for i in $(seq 1 4); do
    sleep 10
    printf "      t+%-3ss  serves=%-4s  %s\n" "$((i*10))" "$(_gw)" "$(_ctl_status)"
  done
  echo "      controller's view (it pushes to the Admin API, which needs etcd):"
  kubectl -n "$_ns" logs deploy/apisix-ingress-controller --tail=6 2>/dev/null \
    | grep -iE 'error|fail|etcd|refus' | tail -3 | sed 's/^/        /' || echo "        (no errors surfaced yet)"

  echo
  echo "      restoring etcd"
  kubectl -n "$_ns" scale statefulset/apisix-etcd --replicas=3 >/dev/null 2>&1
  for i in $(seq 1 18); do
    sleep 10
    [[ "$(kubectl -n "$_ns" get statefulset apisix-etcd -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" == "3" ]] && break
  done
  echo "      etcd back: $(kubectl -n "$_ns" get statefulset apisix-etcd -o jsonpath='{.status.readyReplicas}')/3"

  echo
  echo "    -> HOP A is silent: everything green, config stale, no signal anywhere."
  echo "    -> HOP B degrades loudly on the WRITE path while reads keep working --"
  echo "       APISIX caches its config in the worker, so losing etcd does not drop"
  echo "       traffic. It removes your ability to CHANGE anything."
  echo "    -> the alert you actually want is not 'is the gateway up'. It is"
  echo "       'is the controller's last successful sync recent'."
}

scenario_reset() {
  [[ "$CTL" == "argocd" ]] || return 0
  kubectl -n "$_ns" scale deploy/apisix-ingress-controller --replicas=1 >/dev/null 2>&1
  kubectl -n "$_ns" scale statefulset/apisix-etcd --replicas=3 >/dev/null 2>&1
  kubectl -n "$_demo" patch apisixroute demo --type=json \
    -p='[{"op":"replace","path":"/spec/http/0/backends/0/serviceName","value":"demo-v1"}]' >/dev/null 2>&1
  return 0
}
