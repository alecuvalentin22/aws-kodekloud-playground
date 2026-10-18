#!/usr/bin/env bash
# check.sh -- did you package notes-api as a chart, publish it, and release it properly?
# It READS the chart you wrote, the registry and the cluster. The only thing it
# creates is the `helm test` pod (step 5), which is what `helm test` does.
#
#   ./check.sh                     (any time; on the machine that runs the playground)
#   CHART_DIR=/path/to/chart ./check.sh      judge another chart (default: ~/platform-playground/notes-api/chart/notes-api)
#
# Exit code 0 = every required step passed. Not scored: there is no clock.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "Helm chart exercise check -- chart $CHART_DIR, release $REL in namespace $NS"
echo
echo "0. The playground"
K get nodes >/dev/null 2>&1 && ok "cluster $CTX reachable" || { bad "cluster $CTX is not reachable" "play doctor"; echo; echo "Stopped."; exit 1; }
curl -fsS "http://$REG_HOST/v2/" >/dev/null 2>&1 && ok "registry $REG_HOST reachable" || { bad "registry $REG_HOST is not reachable" "play doctor"; echo; echo "Stopped."; exit 1; }
K get ns "$NS" >/dev/null 2>&1 && ok "namespace $NS exists" || bad "namespace $NS is missing" "./seed.sh"
reg_tags "$IMG_REPO" | grep -qx 1.0.0 && ok "the service image is in the registry ($IMG_REPO:1.0.0)" || bad "image $IMG_REPO:1.0.0 is not in the registry" "./seed.sh"
[[ -f $CHART_DIR/Chart.yaml ]] || { bad "no chart at $CHART_DIR" "step 1: mkdir -p chart && cd chart && helm create notes-api"; echo; echo "Stopped."; exit 1; }

echo; echo "1. The chart's files (step 1 to 4)"
cname=$(sed -n 's/^name: *//p' "$CHART_DIR/Chart.yaml" | tr -d '"' | head -1)
cver=$(sed -n 's/^version: *//p' "$CHART_DIR/Chart.yaml" | tr -d '"' | head -1)
appv=$(sed -n 's/^appVersion: *//p' "$CHART_DIR/Chart.yaml" | tr -d '"' | head -1)
[[ $cname == notes-api ]] && ok "Chart.yaml: name notes-api" || bad "Chart.yaml name is '$cname'" "the chart is called notes-api"
[[ $cver =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+].*)?$ ]] && ok "Chart.yaml: version $cver is SemVer" || bad "Chart.yaml version '$cver' is not SemVer" "version: 0.1.0"
if [[ -n $appv && $appv != 1.16.0 ]]; then ok "Chart.yaml: appVersion $appv (the scaffold's 1.16.0 was replaced)"; else bad "appVersion is '${appv:-missing}'" "it is the version of the SOFTWARE (notes-api 1.0.0), not the scaffold's nginx 1.16.0"; fi
[[ -f $CHART_DIR/values.yaml ]] && ok "values.yaml" || bad "no values.yaml"
[[ -f $CHART_DIR/templates/_helpers.tpl ]] && ok "templates/_helpers.tpl" || bad "no templates/_helpers.tpl" "names and labels written once"
for f in deployment service configmap; do
  [[ -f $CHART_DIR/templates/$f.yaml ]] && ok "templates/$f.yaml" || bad "no templates/$f.yaml"
done
grep -q 'include' "$CHART_DIR"/templates/deployment.yaml 2>/dev/null && grep -q 'selectorLabels\|selector' "$CHART_DIR"/templates/service.yaml 2>/dev/null \
  && ok "the Deployment and the Service use helpers (include)" || bad "templates do not use include helpers" "step 2: labels and selector labels come from _helpers.tpl"
leftover=$(cd "$CHART_DIR/templates" 2>/dev/null && ls hpa.yaml ingress.yaml httproute.yaml serviceaccount.yaml 2>/dev/null | tr '\n' ' ')
[[ -z $leftover ]] && ok "the scaffold's unused templates are deleted" || info "still here from the scaffold: $leftover(fine if you use them; trimming is the point of step 1)"
for env in staging prod; do
  [[ -f $CHART_DIR/values-$env.yaml ]] && ok "values-$env.yaml" || bad "no values-$env.yaml" "step 4"
done
[[ -f $CHART_DIR/values.schema.json ]] && ok "values.schema.json" || bad "no values.schema.json" "step 3"

echo; echo "2. Lint, schema, render (step 3 to 5)"
if H lint "$CHART_DIR" >"$TMP/lint.txt" 2>&1; then ok "helm lint (defaults)"; else bad "helm lint fails" "$(grep -m1 -E '\[ERROR\]' "$TMP/lint.txt")"; fi
for f in "$CHART_DIR"/values-*.yaml; do
  [[ -f $f ]] || continue
  if H lint "$CHART_DIR" -f "$f" >"$TMP/lint.txt" 2>&1; then ok "helm lint -f $(basename "$f")"; else bad "helm lint -f $(basename "$f") fails" "$(grep -m1 -E '\[ERROR\]' "$TMP/lint.txt")"; fi
done
if H template "$REL" "$CHART_DIR" -n "$NS" >"$TMP/base.yaml" 2>"$TMP/err.txt"; then ok "helm template renders with the defaults"; else bad "helm template fails with the defaults" "$(head -c 300 "$TMP/err.txt")"; fi
# Every one of these is a typo that helm template ACCEPTS without a schema (it renders garbage or ignores the key).
rejected=0; accepted=""
for typo in replicaCnt=3 replicaCount=two service.type=NodeProt image.tag=latest; do
  if H template "$REL" "$CHART_DIR" -n "$NS" --set "$typo" >"$TMP/o.txt" 2>&1; then accepted="$accepted $typo"
  elif grep -qi 'schema' "$TMP/o.txt"; then rejected=$((rejected + 1)); fi
done
if (( rejected >= 2 )); then ok "the schema rejects $rejected of 4 realistic typos (replicaCnt=3, replicaCount=two, service.type=NodeProt, image.tag=latest)"
else bad "the schema rejects only $rejected of 4 typos; accepted:$accepted" "step 3: additionalProperties:false, \"type\":\"integer\", an enum for service.type, tag not 'latest'"; fi
[[ -n $accepted && $rejected -ge 2 ]] && info "still accepted by your schema:$accepted"
for env in staging prod; do
  [[ -f $CHART_DIR/values-$env.yaml ]] && H template "$REL" "$CHART_DIR" -n "$NS" -f "$CHART_DIR/values-$env.yaml" >"$TMP/$env.yaml" 2>/dev/null
done
if [[ -s $TMP/staging.yaml && -s $TMP/prod.yaml ]] && ! cmp -s "$TMP/staging.yaml" "$TMP/prod.yaml"; then ok "staging and prod render differently (the env files do something)"
else bad "staging and prod render the same (or do not render)" "step 4: values-prod.yaml must change something real (replicas, resources, config)"; fi
for k in 'kind: Deployment' 'kind: Service' 'kind: ConfigMap' 'checksum/config:' 'livenessProbe:' 'readinessProbe:' 'limits:' 'requests:'; do
  grep -q "$k" "$TMP/base.yaml" && ok "render contains '$k'" || bad "render has no '$k'" "step 2"
done
badimg=$(grep -E 'image: .*:latest|image: "?[^:" ]+"?$' "$TMP/base.yaml" | head -1 | sed 's/^ *//')
if [[ -n $badimg ]]; then bad "an image is untagged or :latest ($badimg)" "pin every tag, the helm test pod's too (the scaffold's busybox has none)"; else ok "no :latest / untagged image in the render"; fi
if K get ns "$NS" >/dev/null 2>&1 && [[ -f $CHART_DIR/values-staging.yaml ]]; then
  if H upgrade --install "$REL" "$CHART_DIR" -n "$NS" -f "$CHART_DIR/values-staging.yaml" --dry-run=server >"$TMP/dry.txt" 2>&1; then ok "helm upgrade --install --dry-run=server: the cluster accepts the chart"
  else bad "the API server rejects the chart (dry-run=server)" "$(grep -m1 -i error "$TMP/dry.txt" | head -c 300)"; fi
fi

echo; echo "3. The chart in the OCI registry (step 6)"
tags=$(reg_tags "$CHART_REPO/notes-api" | tr '\n' ' ')
if [[ -z $tags ]]; then
  bad "no chart in the registry under $CHART_REPO/notes-api" "helm package ... && helm push notes-api-<version>.tgz oci://$REG_HOST/$CHART_REPO --plain-http"
else
  ok "oci://$REG_HOST/$CHART_REPO/notes-api has tags: $tags"
  v=$(echo "$tags" | tr ' ' '\n' | grep -E '^[0-9]' | tail -1)
  if H pull "oci://$REG_HOST/$CHART_REPO/notes-api" --version "$v" --plain-http --destination "$TMP" >/dev/null 2>&1; then
    ok "helm pull works (version $v)"
    lst=$(tar tzf "$TMP"/notes-api-"$v".tgz 2>/dev/null)
    grep -q 'values.schema.json' <<<"$lst" && ok "the published package carries values.schema.json" || bad "the published package has no values.schema.json"
    grep -q 'templates/tests/' <<<"$lst" && ok "the published package carries the helm test" || bad "the published package has no templates/tests/*"
    grep -q 'values-prod.yaml' <<<"$lst" && info "values-*.yaml are inside the package: .helmignore would keep environment files out of it"
  else bad "helm pull of version $v fails"; fi
fi

echo; echo "4. The release (step 6 and 7)"
if ! H -n "$NS" status "$REL" -o json >"$TMP/status.json" 2>/dev/null; then
  bad "no release $REL in $NS" "helm upgrade --install $REL oci://$REG_HOST/$CHART_REPO/notes-api --version <v> --plain-http -n $NS -f values-staging.yaml --atomic --wait"
else
  st=$(jq -r '.info.status' "$TMP/status.json"); rev=$(jq -r '.version' "$TMP/status.json"); chartv=$(H -n "$NS" list -o json 2>/dev/null | jq -r --arg r "$REL" '.[]|select(.name==$r)|.chart')
  [[ $st == deployed ]] && ok "release $REL is deployed (revision $rev, chart $chartv)" || bad "release $REL status is '$st'" "helm -n $NS history $REL"
  if [[ -n $tags ]] && echo " $tags" | grep -q " ${chartv#notes-api-} "; then ok "the running chart version ${chartv#notes-api-} is one that is in the registry"
  else bad "the running chart $chartv is not a version in the registry ($tags)" "install FROM the registry: what was pushed is what runs"; fi
  H -n "$NS" history "$REL" -o json >"$TMP/hist.json" 2>/dev/null
  (( rev >= 3 )) && ok "revision $rev (>= 3)" || bad "only revision $rev" "step 7: install (1), a config upgrade (2), a broken upgrade (3, then the rollback is 4)"
  if jq -e '[.[].status] | index("failed") != null' "$TMP/hist.json" >/dev/null 2>&1; then ok "history has a failed revision (the broken upgrade)"; else bad "history has no failed revision" "step 7: ship a release that cannot become Ready, with --atomic --wait --timeout 60s"; fi
  if jq -e '[.[]] | (map(.status) | index("failed")) as $f | $f != null and ([.[$f+1:][] | select(.description | test("^Rollback to"))] | length > 0)' "$TMP/hist.json" >/dev/null 2>&1
  then ok "a 'Rollback to N' revision follows the failed one: --atomic rolled the bad upgrade back"; else bad "no rollback after the failed revision" "use --atomic (Helm 4 also accepts --rollback-on-failure)"; fi
  H -n "$NS" get hooks "$REL" 2>/dev/null | grep -q 'helm.sh/hook.*test' && ok "the release has a test hook" || bad "no helm.sh/hook: test in the release" "step 2: templates/tests/test-connection.yaml"
fi

echo; echo "5. What is running"
dep=$(K -n "$NS" get deploy -l "app.kubernetes.io/instance=$REL" -o name 2>/dev/null | head -1)
if [[ -z $dep ]]; then
  bad "no Deployment labelled app.kubernetes.io/instance=$REL in $NS" "the standard labels come from _helpers.tpl"
else
  K -n "$NS" get "$dep" -o json >"$TMP/dep.json"
  want=$(jq -r '.spec.replicas' "$TMP/dep.json"); have=$(jq -r '.status.readyReplicas // 0' "$TMP/dep.json")
  upd=$(jq -r '.status.updatedReplicas // 0' "$TMP/dep.json"); tot=$(jq -r '.status.replicas // 0' "$TMP/dep.json")
  if [[ $want -ge 1 && $have == "$want" && $upd == "$want" && $tot == "$want" ]]; then ok "$dep: $have/$want pods Ready, all on the current template"; else bad "$dep: $have/$want Ready ($upd updated, $tot total)" "kubectl -n $NS get pods; describe the one that is not Ready"; fi
  jq -e '.spec.template.metadata.annotations["checksum/config"] | length > 10' "$TMP/dep.json" >/dev/null 2>&1 && ok "the pod template carries a checksum/config annotation" || bad "no checksum/config annotation on the pod template" "step 2: include (print \$.Template.BasePath \"/configmap.yaml\") . | sha256sum"
  nsum=$(K -n "$NS" get rs -l "app.kubernetes.io/instance=$REL" -o json 2>/dev/null | jq -r '[.items[].spec.template.metadata.annotations["checksum/config"] // empty] | unique | length')
  (( nsum >= 2 )) && ok "ReplicaSets carry $nsum different checksums: your config change rolled the pods" || bad "only $nsum distinct checksum in the ReplicaSet history" "step 7: helm upgrade with --set config.MAX_NOTE_LENGTH=100 must roll the pods"
  jq -e '.spec.template.spec.containers[0] | (.livenessProbe and .readinessProbe and .resources.requests and .resources.limits)' "$TMP/dep.json" >/dev/null 2>&1 && ok "container has liveness + readiness probes and requests + limits" || bad "container is missing probes or resources" "step 2"
  img=$(jq -r '.spec.template.spec.containers[0].image' "$TMP/dep.json")
  case "$img" in *:latest|*:) bad "image $img";; *"$IMG_REPO":*) ok "image $img";; *) info "image $img (not the exercise's image repository)";; esac
  for kind in svc cm; do
    K -n "$NS" get "$kind" -l "app.kubernetes.io/instance=$REL" -o json 2>/dev/null | jq -e '.items | length > 0 and all(.[]; .metadata.labels["helm.sh/chart"] != null)' >/dev/null 2>&1 \
      && ok "$kind has the standard labels" || bad "$kind is missing or lacks the standard labels (helm.sh/chart, app.kubernetes.io/instance)"
  done
  svc=$(K -n "$NS" get svc -l "app.kubernetes.io/instance=$REL" -o jsonpath='{.items[0].metadata.name}:{.items[0].spec.ports[0].port}' 2>/dev/null)
  ne=$(K -n "$NS" get endpoints "${svc%%:*}" -o json 2>/dev/null | jq -r '[.subsets[]?.addresses[]?] | length')
  (( ${ne:-0} >= 1 )) && ok "Service ${svc%%:*} has ${ne} endpoints (its selector matches the pods)" || bad "Service has no endpoints" "the Service selector must be the Deployment's selector labels: one helper"
  health=$(K get --raw "/api/v1/namespaces/$NS/services/$svc/proxy/healthz" 2>/dev/null)
  [[ $(jq -r .status <<<"$health" 2>/dev/null) == ok ]] && ok "GET /healthz through the Service -> $health" || bad "GET /healthz through the Service failed"
  root=$(K get --raw "/api/v1/namespaces/$NS/services/$svc/proxy/" 2>/dev/null)
  live=$(jq -r '.max_note_length // empty' <<<"$root" 2>/dev/null)
  cmv=$(K -n "$NS" get cm -l "app.kubernetes.io/instance=$REL" -o jsonpath='{.items[0].data.MAX_NOTE_LENGTH}' 2>/dev/null)
  def=$(H show values "$CHART_DIR" 2>/dev/null | sed -n 's/^ *MAX_NOTE_LENGTH: *//p' | tr -d '"' | head -1)
  if [[ -n $live && $live == "$cmv" ]]; then ok "the app reports max_note_length=$live, the same as the ConfigMap"; else bad "the app reports '${live:-nothing}', the ConfigMap says '${cmv:-nothing}'" "pods that were not restarted after a config change?"; fi
  if [[ -n $live && -n $def && $live != "$def" ]]; then ok "and it is not the chart default ($def): the config upgrade survived the failed upgrade's rollback"
  else bad "max_note_length is still the chart default (${def:-?})" "step 7: upgrade with --set config.MAX_NOTE_LENGTH=100, and keep that revision after the rollback"; fi
fi

echo; echo "6. helm test (runs the test pod)"
if H -n "$NS" status "$REL" >/dev/null 2>&1; then
  if H -n "$NS" test "$REL" --timeout 60s >"$TMP/test.txt" 2>&1; then ok "helm test passes"; else bad "helm test fails" "$(grep -m1 -iE 'error|fail' "$TMP/test.txt" | head -c 300)"; fi
else bad "no release to test"; fi

echo
if (( FAIL == 0 )); then printf '\033[32mAll %d checks passed.\033[0m  Next: say the Q&A out loud, then ./cleanup.sh\n' "$PASS"; exit 0; fi
printf '\033[31m%d passed, %d to do.\033[0m\n' "$PASS" "$FAIL"; exit 1
