#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
[[ -f $SF ]] || { c_bad "no record from break.sh (drill not started properly?)"; exit 1; }
# shellcheck disable=SC1090
source "$SF"        # BREAK_REV BASE_VER V1_UID TAG
scratch="$STATE/scratch/check$N"
trap 'rm -rf "$scratch"' EXIT

# 1. The release exists and is not stuck in a failed upgrade.
st=$(rel_field .info.status); rev=$(rel_field .version)
[[ -n $st ]] || { c_bad "release $REL is gone from $NS (helm -n $NS list)"; exit 1; }
if [[ $st != deployed ]]; then
  c_bad "release $REL is '$st' at revision $rev -- an upgrade failed (helm -n $NS history $REL). Read why before trying again."; exit 1
fi

# 2. A new revision (or a conscious reinstall: the history is the cost of that).
uid=$(K -n "$NS" get secret "sh.helm.release.v1.$REL.v1" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
if [[ $uid != "$V1_UID" ]]; then
  c_warn "release $REL was uninstalled and installed again (revision history lost)"
  echo "PENALTY 10 helm uninstall + install throws away the release history, so you cannot roll back to what ran before. A selector problem in the chart is fixed with helm upgrade."
elif (( rev <= BREAK_REV )); then
  c_bad "release $REL is still at revision $rev, the broken one. Fix the chart and helm upgrade (or run the job)."; exit 1
else
  c_ok "release $REL moved from revision $BREAK_REV to $rev"
fi

# 3. The chart package got a new number, in git and in the cluster.
mainv=$(main_chart_base); livev=$(live_chart_base)
if ! vgt "${mainv:-0}" "$BASE_VER"; then
  c_bad "chart/demo-api/Chart.yaml on main is still version ${mainv:-?}. The templates changed, so the package needs a new version (and it must be pushed)."; exit 1
fi
if ! vgt "${livev:-0}" "$BASE_VER"; then
  c_bad "the running release is still chart $BASE_VER (live: ${livev:-?}). Deploy the fixed chart: push, then run the $JOB job (or helm upgrade)."; exit 1
fi
c_ok "chart version bumped: $BASE_VER -> $mainv in git, $livev running"

# 4. The Service has a selector that the pods match, and endpoints exist.
svc=$(K -n "$NS" get svc "$FULL" -o json 2>/dev/null) || { c_bad "Service $FULL is gone from $NS"; exit 1; }
sel=$(jq -c '.spec.selector // {}' <<<"$svc")
selectorless=0
if [[ $sel == '{}' ]]; then
  selectorless=1
  echo "PENALTY 30 The Service has no selector (hand-made Endpoints/EndpointSlice). It works until a pod is replaced: nothing updates the IPs and readiness stops protecting callers. Fix the label match."
fi
replicas=$(K -n "$NS" get deploy "$FULL" -o jsonpath='{.spec.replicas}' 2>/dev/null)
if [[ -z $replicas || $replicas -lt 2 ]]; then c_bad "deployment $FULL runs ${replicas:-0} replica(s); it was 2. Do not scale your way out of it."; exit 1; fi
K -n "$NS" rollout status "deploy/$FULL" --timeout=60s >/dev/null 2>&1 || { c_bad "deployment $FULL is not fully rolled out"; exit 1; }
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  ready=$(ready_eps)
  (( ${ready:-0} >= replicas )) && break
  sleep 2
done
if (( ${ready:-0} < replicas )); then
  c_bad "Service $FULL has ${ready:-0} ready endpoint(s) for $replicas replicas (kubectl -n $NS get endpointslices)"; exit 1
fi
c_ok "Service $FULL has $ready ready endpoints for $replicas replicas"

# 5. Through the Service, end to end: the chart's own test.
if ! tout=$(HELM -n "$NS" test "$REL" --timeout 90s 2>&1); then
  c_bad "helm test $REL fails"; tail -6 <<<"$tout" | sed 's/^/      /'; exit 1
fi
c_ok "helm test passes (the Service answers /healthz)"

# 6. Did the fix go into the chart, or into the live objects?
#    (a) the live Service selector must be what helm rendered for this revision;
#    (b) the chart on main must render a Service that selects its own Deployment's pods.
live_sel=$(jq -S -c '.spec.selector // {}' <<<"$svc")
man=$(HELM -n "$NS" get manifest "$REL" 2>/dev/null | objs_json)
man_sel=$(jq -S -c 'map(select(.kind=="Service"))[0].spec.selector // {}' <<<"$man")
drift=0
[[ $live_sel == "$man_sel" ]] || drift=1
rm -rf "$scratch"; git clone -q "$(repo_url "$REPO")" "$scratch" 2>/dev/null || { c_bad "cannot clone $REPO"; exit 1; }
rendered=$(HELM template "$REL" "$scratch/chart/demo-api" -n "$NS" -f "$scratch/chart/demo-api/values-staging.yaml" 2>/dev/null | objs_json)
sel_matches <<<"$rendered" || drift=1
if (( drift && ! selectorless )); then
  echo "PENALTY 20 The Service works because of a change made to the live object (kubectl edit/patch), not because the chart renders a matching selector. The next helm upgrade or pipeline run puts the bug back. Fix the template."
elif (( ! selectorless )); then
  c_ok "the chart on main renders a Service that selects its own pods; live matches helm's manifest"
fi
exit 0
