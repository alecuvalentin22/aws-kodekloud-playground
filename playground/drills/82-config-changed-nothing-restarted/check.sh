#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
[[ -f $SF ]] || { c_bad "no record from break.sh (drill not started properly?)"; exit 1; }
# shellcheck disable=SC1090
source "$SF"        # BREAK_REV BASE_VER V1_UID TAG
scratch="$STATE/scratch/check$N"
trap 'rm -rf "$scratch"' EXIT

# pod_versions -- "pod value" for each running, non-terminating pod of the app (the test pod is not one)
pod_versions() {
  local p
  for p in $(K -n "$NS" get pods -l "app.kubernetes.io/name=demo-api,app.kubernetes.io/instance=$REL" -o json 2>/dev/null \
             | jq -r '.items[] | select(.metadata.deletionTimestamp==null and .status.phase=="Running") | .metadata.name'); do
    echo "$p $(K -n "$NS" exec "$p" -- printenv VERSION 2>/dev/null)"
  done
}
# all_pods_run WANT -- every running pod has VERSION=WANT, and there are as many as replicas
all_pods_run() {
  local want=$1 want_n lines n good
  want_n=$(K -n "$NS" get deploy "$FULL" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  lines=$(pod_versions); n=$(grep -c . <<<"$lines")
  good=$(awk -v w="$want" '$2==w' <<<"$lines" | grep -c .)
  (( n >= 1 && n == good && n >= ${want_n:-1} ))
}

# 1. The release.
st=$(rel_field .info.status); rev=$(rel_field .version)
[[ -n $st ]] || { c_bad "release $REL is gone from $NS (helm -n $NS list)"; exit 1; }
[[ $st == deployed ]] || { c_bad "release $REL is '$st' at revision $rev (helm -n $NS history $REL)"; exit 1; }
uid=$(K -n "$NS" get secret "sh.helm.release.v1.$REL.v1" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
if [[ $uid != "$V1_UID" ]]; then
  c_warn "release $REL was uninstalled and installed again (revision history lost)"
  echo "PENALTY 10 helm uninstall + install throws away the release history. A template fix is a helm upgrade."
elif (( rev <= BREAK_REV )); then
  c_bad "release $REL is still at revision $rev, the one where the label did not reach the pods. Fix the chart and upgrade (or run the job)."; exit 1
else
  c_ok "release $REL moved from revision $BREAK_REV to $rev"
fi

# 2. Chart: a new package number, in git and running.
mainv=$(main_chart_base); livev=$(live_chart_base)
vgt "${mainv:-0}" "$BASE_VER" || { c_bad "chart/demo-api/Chart.yaml on main is still version ${mainv:-?}; a template change needs a new version, pushed."; exit 1; }
vgt "${livev:-0}" "$BASE_VER" || { c_bad "the running release is still chart $BASE_VER (live: ${livev:-?}). Deploy the fixed chart: push, then run the $JOB job."; exit 1; }
c_ok "chart version bumped: $BASE_VER -> $mainv in git, $livev running"

# 3. What does the Deployment template on main do about config changes?
rm -rf "$scratch"; git clone -q "$(repo_url "$REPO")" "$scratch" 2>/dev/null || { c_bad "cannot clone $REPO"; exit 1; }
dep=$(grep -vE '^[[:space:]]*#' "$scratch/chart/demo-api/templates/deployment.yaml")
has_ck=0; has_rand=0
grep -Eq 'checksum|sha256sum' <<<"$dep" && grep -q 'configmap.yaml' <<<"$dep" && has_ck=1
grep -Eq 'randAlpha|randNumeric|randAscii|uuidv4|(^|[^[:alnum:]_])now([^[:alnum:]_]|$)|[^[:alnum:]_]date[[:space:]]' <<<"$dep" && has_rand=1
live_ann=$(K -n "$NS" get deploy "$FULL" -o json | jq -r '(.spec.template.metadata.annotations // {}) | del(.["kubectl.kubernetes.io/restartedAt"]) | keys | join(",")')
restarted=$(K -n "$NS" get deploy "$FULL" -o json | jq -r '.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] // empty')
if (( ! has_ck && ! has_rand )); then
  c_bad "templates/deployment.yaml on main has no annotation that changes when the ConfigMap changes (no checksum/config)."
  [[ -n $restarted ]] && c_bad "The pods were restarted by hand (kubectl rollout restart, $restarted). That shows the new label once; the next config change would not roll them again."
  exit 1
fi
if [[ -z $live_ann ]]; then
  c_bad "the running Deployment's pod template carries no rollout annotation: the fixed chart is not what runs (push, then run the $JOB job / helm upgrade)."
  [[ -n $restarted ]] && c_bad "Restarting the pods by hand is not the fix: the next config change would not roll them."
  exit 1
fi
c_ok "the pod template on main and in the cluster carries a rollout trigger (${live_ann})"

# 4. The pods run the config the ConfigMap holds, and the Service serves it.
cm=$(K -n "$NS" get cm "$FULL" -o jsonpath='{.data.VERSION}' 2>/dev/null)
[[ -n $cm ]] || { c_bad "ConfigMap $FULL has no VERSION"; exit 1; }
ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do all_pods_run "$cm" && { ok=1; break; }; sleep 3; done
if (( ! ok )); then
  c_bad "the pods do not all run VERSION=$cm (the ConfigMap):"; pod_versions | sed 's/^/      /'; exit 1
fi
served=$(svc_get / | jq -r .version 2>/dev/null)
[[ $served == "$cm" ]] || { c_bad "GET / through the Service answers version '$served', ConfigMap says '$cm'"; exit 1; }
c_ok "every pod runs VERSION=$cm and GET / answers it"

# 5. The real proof: change the config once more through Helm, WITHOUT changing the chart version
#    (the version is a pod label; a new one would roll the pods by itself), and watch the pods.
#    Reverted afterwards with helm rollback.
probe="check82-$(date +%s)"; before=$(rel_field .version)
livefull=$(HELM -n "$NS" list -o json 2>/dev/null | jq -r --arg r "$REL" '.[]|select(.name==$r)|.chart' | sed -E 's/^demo-api-//')
pkgdir="$scratch/pkg"; mkdir -p "$pkgdir"
if ! HELM package "$scratch/chart/demo-api" --version "$livefull" -d "$pkgdir" >/dev/null 2>&1; then
  c_bad "cannot package the chart on main as version $livefull (helm lint chart/demo-api)"; exit 1
fi
c_dim "  proving a config-only change rolls the pods: helm upgrade --set config.VERSION=$probe (chart $livefull unchanged), then rollback"
if ! up=$(HELM -n "$NS" upgrade "$REL" "$pkgdir/demo-api-$livefull.tgz" --reuse-values --set "config.VERSION=$probe" \
          --wait --timeout 150s --description "drill $N check: does a config-only change roll the pods?" 2>&1); then
  c_bad "the proof upgrade failed:"; tail -5 <<<"$up" | sed 's/^/      /'
  HELM -n "$NS" rollback "$REL" "$before" --wait --timeout 150s >/dev/null 2>&1; exit 1
fi
rolled=0
for _ in $(seq 1 25); do all_pods_run "$probe" && { rolled=1; break; }; sleep 3; done
if (( ! rolled )); then
  c_bad "a config-only change (VERSION=$probe) reached the ConfigMap but the pods did not restart:"; pod_versions | sed 's/^/      /'
  HELM -n "$NS" rollback "$REL" "$before" --wait --timeout 150s >/dev/null 2>&1; exit 1
fi
c_ok "the pods rolled by themselves onto the new config"
HELM -n "$NS" rollback "$REL" "$before" --wait --timeout 150s >/dev/null 2>&1 || c_warn "could not roll the proof back; run: helm -n $NS rollback $REL $before"
for _ in $(seq 1 25); do all_pods_run "$cm" && break; sleep 3; done

# 6. How was the trigger made?
if (( has_rand )); then
  echo "PENALTY 15 The rollout annotation is random or time-based (randAlphaNum, now, uuidv4...): it restarts every pod on EVERY upgrade, even when nothing changed. Hash the ConfigMap so it changes only when the config does."
fi
exit 0
