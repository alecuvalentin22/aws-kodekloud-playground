#!/usr/bin/env bash
# Fixed means, judged on the LIVE cluster (not on the manifest file):
#   1. the ledger Deployment (>= 2 replicas, rolled out) and the ledger Service exist,
#   2. the Service's EndpointSlices hold >= 2 READY endpoints that point at ledger pods,
#   3. a fresh exec inside a checkout pod gets HTTP 200 from http://ledger:8080/,
#   4. checkout's latest log line is OK.
# PENALTY 30: checkout's pod template hard-codes the ledger Service ClusterIP or a pod IP.
# PENALTY 20: the Service has no selector / its endpoints are hand-made (not managed by
#             the EndpointSlice controller).
# PENALTY 10: ledger pods carry labels their Deployment template does not (a pod-level
#             `kubectl label pod`), which a rollout or reschedule wipes.
# API calls (kube only): get ns/deploy/svc/endpointslices/pods, rollout status, exec (python), logs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
REC="$STATE/drill74.env"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
NS=""
# shellcheck disable=SC1090
source "$REC"
[[ $NS == platform-lab-drill74 ]] || { c_bad "bad record in $REC"; exit 1; }

# 1. ledger Deployment and Service exist and are healthy
K -n "$NS" get deploy ledger >/dev/null 2>&1 || { c_bad "deployment ledger is gone from $NS"; exit 1; }
K -n "$NS" get svc ledger >/dev/null 2>&1 || { c_bad "service ledger is gone from $NS"; exit 1; }
reps=$(K -n "$NS" get deploy ledger -o jsonpath='{.spec.replicas}')
if (( ${reps:-0} < 2 )); then c_bad "ledger runs ${reps:-0} replica(s); it had 2 and nobody asked to scale it down"; exit 1; fi
K -n "$NS" rollout status deploy/ledger --timeout=90s >/dev/null 2>&1 \
  || { c_bad "ledger is not rolled out (kubectl -n $NS get pods)"; exit 1; }
svcjson=$(K -n "$NS" get svc ledger -o json)
svcip=$(jq -r '.spec.clusterIP' <<<"$svcjson")
sel=$(jq -c '.spec.selector // {}' <<<"$svcjson")
podips=$(K -n "$NS" get pods -l "$(K -n "$NS" get deploy ledger -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')" \
           -o jsonpath='{.items[*].status.podIP}')
c_ok "ledger is rolled out ($reps replicas) and its Service exists ($svcip)"

# 2. the Service has ready endpoints
slices=$(K -n "$NS" get endpointslices -l kubernetes.io/service-name=ledger -o json)
ready=$(jq '[.items[].endpoints[]? | select((.conditions.ready // true) == true)] | length' <<<"$slices")
podbacked=$(jq '[.items[].endpoints[]? | select((.conditions.ready // true) == true and .targetRef.kind == "Pod")] | length' <<<"$slices")
if (( ready < 2 )); then
  c_bad "the ledger Service has $ready ready endpoint(s) (need 2): traffic to it has nowhere to go"
  c_bad "Service selector: $sel"
  c_bad "ledger pod labels: $(K -n "$NS" get pods -o json | jq -r '[.items[] | select(.metadata.name | startswith("ledger")) | .metadata.labels | del(."pod-template-hash")] | unique | map(tostring) | join(" ; ")')"
  exit 1
fi
c_ok "EndpointSlice(s) for ledger: $ready ready endpoint(s)"

# 3. a fresh request from inside a checkout pod
K -n "$NS" get deploy checkout >/dev/null 2>&1 || { c_bad "deployment checkout is gone from $NS"; exit 1; }
K -n "$NS" rollout status deploy/checkout --timeout=90s >/dev/null 2>&1 \
  || { c_bad "checkout is not rolled out (kubectl -n $NS get pods)"; exit 1; }
tmpl=$(K -n "$NS" get deploy checkout -o json | jq -c '.spec.template.spec')
pod=$(K -n "$NS" get pods -l app=checkout -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running")][0].metadata.name // empty')
[[ -n $pod ]] || { c_bad "no Running checkout pod"; exit 1; }
out=$(K -n "$NS" exec "$pod" -- python -c '
import urllib.request
print(urllib.request.urlopen("http://ledger:8080/", timeout=4).status)' 2>&1); rc=$?
if (( rc != 0 )); then
  c_bad "inside $pod, http://ledger:8080/ still fails: $(tail -n 1 <<<"$out" | cut -c1-300)"; exit 1
fi
if [[ $(tail -n 1 <<<"$out") != 200 ]]; then c_bad "ledger answered, but not with 200: $(tail -n 1 <<<"$out")"; exit 1; fi
c_ok "inside $pod: http://ledger:8080/ answers HTTP 200"

# 4. the application's own log
ok=no
for _ in $(seq 1 10); do
  last=$(K -n "$NS" logs "$pod" --tail=1 2>/dev/null)
  if grep -q ' OK 200 ' <<<"$last"; then ok=yes; break; fi
  sleep 3
done
[[ $ok == yes ]] || { c_bad "checkout's latest log line is not OK: ${last:-empty}"; exit 1; }
c_ok "checkout logs: $last"

# Penalties (only echoed when everything above passed; play check strips the lines).
hard=no
for ip in $svcip $podips; do
  [[ -n $ip && $ip != None ]] || continue
  pat=${ip//./\\.}
  if grep -Eq "(^|[^0-9.])${pat}([^0-9.]|$)" <<<"$tmpl"; then hard=$ip; fi
done
if [[ $hard != no ]]; then
  c_warn "checkout's pod template hard-codes the ledger address ($hard)"
  echo "PENALTY 30 The ledger address ($hard) is hard-coded in checkout's pod template. A pod IP changes on every restart and a Service ClusterIP when the Service is re-created; the NAME is the contract, and it works once the Service selects the pods."
fi
manual=no
[[ $sel == '{}' ]] && manual=yes
[[ $(jq '[.items[] | select(.metadata.labels["endpointslice.kubernetes.io/managed-by"] != "endpointslice-controller.k8s.io")] | length' <<<"$slices") -gt 0 ]] && manual=yes
if [[ $manual == yes ]]; then
  c_warn "the ledger Service has no selector or hand-made endpoints"
  echo "PENALTY 20 The ledger Service is selector-less with endpoints written by hand. It works until a pod is replaced: nothing updates the IPs, readiness no longer removes a dead pod, and the real fault (selector vs labels) is still there. Fix the selector and let the EndpointSlice controller do its job."
fi
sk=$(K -n "$NS" get deploy ledger -o json | jq -c '.spec.template.metadata.labels')
bad=$(K -n "$NS" get pods -o json | jq --argjson t "$sk" '[.items[] | select(.metadata.name | startswith("ledger-")) | select(.metadata.deletionTimestamp == null)
        | select((.metadata.labels | del(."pod-template-hash")) != $t)] | length')
if (( bad > 0 )); then
  c_warn "$bad ledger pod(s) carry labels the Deployment template does not have"
  echo "PENALTY 10 $bad ledger pod(s) have labels that were patched onto the pod only (kubectl label pod). The Deployment template does not carry them, so the next rollout, eviction or scale-up brings back pods the Service does not select. Change the Service selector, or the template."
fi
exit 0
