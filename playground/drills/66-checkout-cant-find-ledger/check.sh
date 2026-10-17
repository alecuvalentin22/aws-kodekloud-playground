#!/usr/bin/env bash
# Fixed means, judged on the LIVE cluster (not on the manifest file):
#   1. ledger (Deployment + Service) is still there and Ready,
#   2. checkout is rolled out and its pod's /etc/resolv.conf nameserver is the
#      kube-dns Service ClusterIP (so dnsPolicy is ClusterFirst / unset, or the
#      brittle None + hand-written dnsConfig),
#   3. a fresh exec inside a checkout pod resolves `ledger` and gets HTTP 200,
#   4. checkout's latest log line is OK.
# PENALTY 40: the checkout pod template hard-codes the ledger Service ClusterIP or a
#             ledger pod IP (env, args, command, hostAliases).
# PENALTY 20: dnsPolicy None with a hand-written dnsConfig pointing at CoreDNS.
# API calls (kube only): get ns/deploy/svc/pods, rollout status, exec (python, cat), logs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
REC="$STATE/drill66.env"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
NS=""
# shellcheck disable=SC1090
source "$REC"
[[ $NS == platform-lab-drill66 ]] || { c_bad "bad record in $REC"; exit 1; }

# 1. ledger untouched and healthy
K -n "$NS" get deploy ledger >/dev/null 2>&1 || { c_bad "deployment ledger is gone from $NS: the fix belongs on checkout, ledger was fine"; exit 1; }
K -n "$NS" get svc ledger >/dev/null 2>&1 || { c_bad "service ledger is gone from $NS"; exit 1; }
K -n "$NS" rollout status deploy/ledger --timeout=60s >/dev/null 2>&1 || { c_bad "ledger is not Ready"; exit 1; }
svcip=$(K -n "$NS" get svc ledger -o jsonpath='{.spec.clusterIP}')
podips=$(K -n "$NS" get pods -l app=ledger -o jsonpath='{.items[*].status.podIP}')
c_ok "ledger is Running and its Service exists ($svcip)"

# 2. checkout rolled out
K -n "$NS" get deploy checkout >/dev/null 2>&1 || { c_bad "deployment checkout is gone from $NS"; exit 1; }
K -n "$NS" rollout status deploy/checkout --timeout=90s >/dev/null 2>&1 \
  || { c_bad "checkout is not rolled out (still starting, or a bad edit: kubectl -n $NS get pods)"; exit 1; }
tmpl=$(K -n "$NS" get deploy checkout -o json | jq -c '.spec.template.spec')
policy=$(jq -r '.dnsPolicy // "ClusterFirst"' <<<"$tmpl")
hostnet=$(jq -r '.hostNetwork // false' <<<"$tmpl")
pod=$(K -n "$NS" get pods -l app=checkout -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running")][0].metadata.name // empty')
[[ -n $pod ]] || { c_bad "no Running checkout pod"; exit 1; }
c_ok "checkout pod $pod is Running (dnsPolicy $policy)"

kubedns=$(K -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
resolv=$(K -n "$NS" exec "$pod" -- cat /etc/resolv.conf 2>/dev/null)
ns_found=$(awk '$1=="nameserver"{print $2; exit}' <<<"$resolv")
search=$(awk '$1=="search"{$1=""; print; exit}' <<<"$resolv")
if [[ -z $kubedns || $ns_found != "$kubedns" ]]; then
  c_bad "the pod's /etc/resolv.conf nameserver is ${ns_found:-none}, not the cluster DNS Service ($kubedns); search:${search:- none}"
  if [[ $policy == Default ]]; then
    c_bad "dnsPolicy is Default: the pod inherits the node's resolver, which knows nothing about Service names"
  elif [[ $hostnet == true ]]; then
    c_bad "hostNetwork is true: a host-network pod needs dnsPolicy ClusterFirstWithHostNet to use cluster DNS"
  fi
  exit 1
fi
c_ok "resolv.conf nameserver is kube-dns ($kubedns)"

# 3. a fresh lookup and request from inside the pod
out=$(K -n "$NS" exec "$pod" -- python -c '
import socket, urllib.request
print(socket.gethostbyname("ledger"))
print(urllib.request.urlopen("http://ledger:8080/", timeout=4).status)' 2>&1); rc=$?
if (( rc != 0 )); then
  c_bad "inside $pod, ledger still does not work: $(tail -n 1 <<<"$out" | cut -c1-300)"
  if [[ $policy == None ]]; then
    c_bad "dnsPolicy None: the pod has ONLY what dnsConfig says -- does it have the search domains (the name 'ledger' needs ${NS}.svc.cluster.local)?"
  fi
  exit 1
fi
if [[ $(tail -n 1 <<<"$out") != 200 ]]; then c_bad "ledger answered, but not with 200: $(tail -n 1 <<<"$out")"; exit 1; fi
c_ok "inside the pod: ledger resolves to $(head -n 1 <<<"$out") and answers HTTP 200"

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
  [[ -n $ip ]] || continue
  pat=${ip//./\\.}
  if grep -Eq "(^|[^0-9.])${pat}([^0-9.]|$)" <<<"$tmpl"; then hard=$ip; fi
done
if [[ $hard == no ]] && jq -e '(.hostAliases // []) | map(select(.hostnames | index("ledger"))) | length > 0' <<<"$tmpl" >/dev/null 2>&1; then
  hard=hostAliases
fi
if [[ $hard != no ]]; then
  c_warn "checkout's pod template hard-codes the ledger address ($hard)"
  echo "PENALTY 40 The ledger address ($hard) is hard-coded in checkout's pod template. A Service ClusterIP is not a contract (it changes when the Service is re-created) and a pod IP changes on every restart; the NAME is the contract, and it resolves once DNS is right."
fi
if [[ $policy == None ]]; then
  c_warn "dnsPolicy None with a hand-written dnsConfig"
  echo "PENALTY 20 dnsPolicy None with a hand-written dnsConfig works, but it is brittle: the CoreDNS Service IP, the search domains and ndots are now copied by hand into this one Deployment and silently drift from the cluster (a new kube-dns IP or a renamed domain breaks only this pod). ClusterFirst gives the same result by design, and dnsConfig.options (ndots) is the supported way to tune on top of it."
fi
exit 0
