# QUESTION: A canary is failing at 10% of traffic. Does your dashboard show it?
# EXPECT: No. Both branches share one route label, so route-level error rate barely moves.
#
# This is the scenario worth leading with, because it is the honest answer to
# the question every interviewer asks about canaries -- "how did you know it was
# safe to proceed?" -- and the answer most people give is wrong.
#
# The arithmetic is the whole point. v2 gets 10% of traffic and returns 500 on
# every request. Route-level success rate goes from 100% to 90%. If your alert
# threshold is 95%, it fires. If it is 99%, it fires. If it is anything
# reasonable for a service that also has real background noise, it MIGHT fire --
# and the graph you are looking at moves by a single-digit percentage that is
# indistinguishable from a bad afternoon.
#
# Now make it 2% canary traffic instead of 10%, which is what a real first step
# looks like. Success rate 100% -> 98%. Nothing fires. Nothing looks wrong.
# The canary is completely broken and the dashboard is green.
#
# The fix is not a better threshold. It is a label that distinguishes the
# branches, because you cannot alert on a dimension you did not record.
#
# Also measured here: traffic-split is STATELESS PER REQUEST. A user browsing
# the site hits both branches, which is fine for a canary and fatal for an A/B
# test -- see scenario 08 for the distinction.

_ns=apisix
_demo=demo-apisix
_host=demo.apisix.local
_LOOP=200

# Send N requests through the gateway and tally which version answered.
_tally() {
  local n="${1:-$_LOOP}" extra="${2:-}"
  kubectl -n "$_demo" run tally-$RANDOM --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.10.1 -- sh -c "
      v1=0; v2=0; err=0
      for i in \$(seq 1 $n); do
        body=\$(curl -s --max-time 5 -o - -w '\n%{http_code}' -H 'Host: $_host' $extra \
                http://apisix-gateway.$_ns:80/ 2>/dev/null)
        code=\$(echo \"\$body\" | tail -1)
        if [ \"\$code\" != '200' ]; then err=\$((err+1))
        elif echo \"\$body\" | grep -q 'v2'; then v2=\$((v2+1))
        elif echo \"\$body\" | grep -q 'v1'; then v1=\$((v1+1))
        fi
      done
      echo \"v1=\$v1 v2=\$v2 non200=\$err of $n\"
    " 2>/dev/null | tail -1
}

_prom() {
  # Query the Prometheus that Phase 1 installed, from inside the cluster.
  kubectl -n observability run promq-$RANDOM --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.10.1 -- \
    curl -s --max-time 8 -G --data-urlencode "query=$1" \
    'http://kube-prometheus-stack-prometheus.observability:9090/api/v1/query' 2>/dev/null \
    | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    r=d["data"]["result"]
    if not r: print("      (no series)")
    for x in r[:8]:
        m={k:v for k,v in x["metric"].items() if k in ("route","service","code","node")}
        print("      ", m, "=", round(float(x["value"][1]),2))
except Exception as e: print("      (query failed)", e)' 2>/dev/null
}

scenario_apply() {
  [[ "$CTL" == "argocd" ]] || { echo "    (gateway-level; runs once)"; return 0; }
  kubectl -n "$_demo" get apisixroute demo >/dev/null 2>&1 || {
    echo "    APISIX demo route missing -- run: make apisix"; return 1; }
  echo "    baseline, all traffic to v1:"
  echo "      $(_tally 40)"
}

scenario_observe() {
  [[ "$CTL" == "argocd" ]] || return 0

  # ==========================================================================
  echo
  echo "    [1] traffic-split 90/10, plus a header rule forcing v2."
  echo "        Rule ORDER matters: first match wins, so the unconditional"
  echo "        weighted rule must come LAST or it swallows everything."
  kubectl apply -f "$ROOT/kubernetes/apisix/demo/03-split.yaml" 2>&1 | sed 's/^/      /'
  sleep 25

  echo
  echo "    [2] is the configured ratio the OBSERVED ratio? ($_LOOP requests)"
  echo "        $(_tally $_LOOP)"
  echo "        -> expect roughly 90/10. Weighted split is probabilistic per"
  echo "           request, so exact 180/20 would be suspicious, not reassuring."

  echo
  echo "    [3] the header rule -- 40 requests with x-canary: always"
  echo "        $(_tally 40 "-H 'x-canary: always'")"
  echo "        -> 100% v2. That is a PREDICATE, not a percentage."

  echo
  echo "    [4] STICKINESS: traffic-split is stateless per request."
  echo "        20 requests that a single browsing user would generate:"
  echo "        $(_tally 20)"
  echo "        -> a user who reloads lands on both branches. Fine for a canary"
  echo "           (you want a random sample); fatal for an A/B test, where the"
  echo "           cohort must be stable or the measurement means nothing."

  # ==========================================================================
  echo
  echo "    [5] NOW BREAK v2 -- and watch the dashboard not notice."
  kubectl -n "$_demo" patch deploy demo-v2 --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/command","value":["/home/app/podinfo"]},
    {"op":"add","path":"/spec/template/spec/containers/0/args","value":["--random-error"]}
  ]' 2>&1 | sed 's/^/      /'
  kubectl -n "$_demo" rollout status deploy/demo-v2 --timeout=180s 2>&1 | tail -1 | sed 's/^/      /'
  sleep 20

  echo
  echo "      generating load so the metrics have something to measure"
  _tally $_LOOP >/dev/null 2>&1
  echo "      $(_tally $_LOOP)"

  echo
  echo "      what the ROUTE-LEVEL metric says (this is the blind spot):"
  _prom 'sum by (route,code) (increase(apisix_http_status[5m]))'
  echo
  echo "      -> both branches are the SAME route, so the 500s from v2 are"
  echo "         averaged into the route's total. At 10% canary weight a fully"
  echo "         broken v2 moves route success rate from 100% to ~90%."
  echo "         At a realistic first step of 2%, it moves it to 98% and"
  echo "         absolutely nothing fires."

  # ==========================================================================
  echo
  echo "    [6] FIX THE VISIBILITY -- same break, separate routes per branch."
  kubectl apply -f "$ROOT/kubernetes/apisix/demo/04-split-observable.yaml" 2>&1 | sed 's/^/      /'
  sleep 25
  _tally $_LOOP >/dev/null 2>&1
  echo "      $(_tally $_LOOP)"
  echo
  echo "      the same query, now that the branches carry different route labels:"
  _prom 'sum by (route,code) (increase(apisix_http_status[5m]))'
  echo
  echo "      -> the canary route's error rate is now its own series. THAT is"
  echo "         something you can alert on, and it does not get quieter as you"
  echo "         reduce the canary weight -- which is the property you want,"
  echo "         because a smaller canary should not be a less visible one."

  echo
  echo "    -> the deliverable is the CONTRAST between [5] and [6]:"
  echo "       identical breakage, invisible then visible, one label apart."
}

scenario_reset() {
  [[ "$CTL" == "argocd" ]] || return 0
  kubectl -n "$_demo" patch deploy demo-v2 --type=json \
    -p='[{"op":"remove","path":"/spec/template/spec/containers/0/args"}]' >/dev/null 2>&1
  kubectl -n "$_demo" patch deploy demo-v2 --type=json \
    -p='[{"op":"remove","path":"/spec/template/spec/containers/0/command"}]' >/dev/null 2>&1
  kubectl apply -f "$ROOT/kubernetes/apisix/demo/02-route.yaml" >/dev/null 2>&1
  kubectl -n "$_demo" delete apisixroute demo-canary >/dev/null 2>&1
  return 0
}
