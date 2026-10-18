#!/usr/bin/env bash
# A "tidy-up" of _helpers.tpl: the Service gets its own selector helper, built from
# the release-qualified name (fullname) while the Deployment and its pods keep
# selectorLabels (built from the chart name). For a release called "demo-api" the
# two are the same string; for release "checkout" they are not. The upgrade
# succeeds, the pods are Ready, the Service has zero endpoints, helm test is red.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
leftovers_guard

img=$(K -n demo-ci get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ $img == *:* ]] || { echo "demo-api is not deployed in demo-ci -- run: play reset"; exit 1; }
TAG=${img##*:}

# 1. The repo (the chart as the platform team ships it), the namespace and the pipeline's Role.
d="$STATE/scratch/seed$N"
seed_dir "$d" "$TAG"
repo_publish "$d"
apply_rbac "$d"

# 2. Release revision 1: the chart as it was, installed the way the team first did it.
HELM -n "$NS" upgrade --install "$REL" "$d/chart/demo-api" -f "$d/chart/demo-api/values-staging.yaml" \
  --set image.repository="$REGISTRY/platform-lab/demo-api" --set image.tag="$TAG" \
  --wait --timeout 150s --description "first install (helm CLI), chart as imported" >/dev/null
V1_UID=$(K -n "$NS" get secret "sh.helm.release.v1.$REL.v1" -o jsonpath='{.metadata.uid}')
rm -rf "$d"

# 3. The tidy-up. Lena splits the Service's selector off selectorLabels "to be able to move the
#    Service to the new labelling scheme later". Chart version NOT bumped.
as_teammate "Lena (checkout)" "$REPO" "helpers: give the Service its own selector helper (fullname, unique per release)" <<'SH'
python3 - <<'PY'
p = "chart/demo-api/templates/_helpers.tpl"
s = open(p).read()
marker = "{{/*\nStandard labels on every object."
assert marker in s
new = '''{{/*
Service selector. Lena (checkout): the Service used to share selectorLabels with
the Deployment. It gets its own helper, unique per release (fullname), so the
Service can move to the new labelling scheme later without touching the
Deployment selector, which Kubernetes does not allow to change.
*/}}
{{- define "demo-api.serviceSelector" -}}
app.kubernetes.io/name: {{ include "demo-api.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

'''
open(p, "w").write(s.replace(marker, new + marker, 1))
p = "chart/demo-api/templates/service.yaml"
s = open(p).read()
old = 'include "demo-api.selectorLabels" .'
assert old in s
open(p, "w").write(s.replace(old, 'include "demo-api.serviceSelector" .', 1))
PY
SH

# 4. The pipeline runs it: Deploy goes through (pods Ready is all --wait asks), Test goes red.
job_scm "$TAG"
out="$STATE/scratch/break$N.console"
job_run "$out" 420 "IMAGE_TAG=$TAG"
case $JOB_RESULT in FAILURE|SUCCESS) ;; *) echo "the first run of $JOB ended $JOB_RESULT -- see $JENKINS_URL/job/$JOB/$JOB_NUM/console"; tail -25 "$out"; exit 1 ;; esac

# 5. Make sure the incident is what the ticket says.
rev=$(HELM -n "$NS" status "$REL" -o json | jq -r .version)
[[ $rev == 2 ]] || { echo "expected release revision 2, found $rev"; tail -25 "$out"; exit 1; }
K -n "$NS" rollout status "deploy/$FULL" --timeout=60s >/dev/null
eps=$(K -n "$NS" get endpointslices -l "kubernetes.io/service-name=$FULL" -o json | jq '[.items[].endpoints[]?] | length')
[[ $eps == 0 ]] || { echo "the Service has $eps endpoints; the break did not take"; exit 1; }
rm -f "$out"

printf 'BREAK_REV=%s\nBASE_VER=%s\nV1_UID=%s\nTAG=%s\n' "$rev" 0.1.0 "$V1_UID" "$TAG" > "$SF"
player_clone
