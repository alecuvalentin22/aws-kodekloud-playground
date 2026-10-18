#!/usr/bin/env bash
# Lena removes the checksum/config annotation from the Deployment's pod template
# ("it restarts staging on every config tweak, and the diffs are noisy"). Without
# it a ConfigMap change never changes the template, so no pod restarts: the next
# release label (a values change) reaches the ConfigMap, helm says deployed, and
# GET / keeps answering with the old label.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
leftovers_guard

img=$(K -n demo-ci get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ $img == *:* ]] || { echo "demo-api is not deployed in demo-ci -- run: play reset"; exit 1; }
TAG=${img##*:}

# 1. The repo: the chart as imported, plus a release label in staging's config
#    (the app echoes VERSION on GET /, which makes a config change visible).
d="$STATE/scratch/seed$N"
seed_dir "$d" "$TAG"
python3 - "$d" <<'PY'
import sys
p = sys.argv[1] + "/chart/demo-api/values-staging.yaml"
s = open(p).read()
old = 'config:\n  FAIL_HEALTH: "false"\n'
assert old in s
open(p, "w").write(s.replace(old, old + '  # Release label. The app returns it as "version" on GET /.\n  VERSION: "2026.10.1"\n'))
PY
repo_publish "$d"
apply_rbac "$d"

# 2. Revision 1: installed as imported (annotation present).
HELM -n "$NS" upgrade --install "$REL" "$d/chart/demo-api" -f "$d/chart/demo-api/values-staging.yaml" \
  --set image.repository="$REGISTRY/platform-lab/demo-api" --set image.tag="$TAG" \
  --wait --timeout 150s --description "first install (helm CLI), chart as imported" >/dev/null
V1_UID=$(K -n "$NS" get secret "sh.helm.release.v1.$REL.v1" -o jsonpath='{.metadata.uid}')
rm -rf "$d"

# 3. The tidy-up. Lena removes the annotation and its comment. Chart version NOT bumped.
as_teammate "Lena (payments)" "$REPO" "deployment: drop checksum/config (staging restarted on every config tweak, noisy diffs)" <<'SH'
python3 - <<'PY'
import re
p = "chart/demo-api/templates/deployment.yaml"
s = open(p).read()
new, n = re.subn(r"      annotations:\n        # Pods only restart.*?\n        \{\{- with \.Values\.podAnnotations \}\}\n        \{\{- toYaml \. \| nindent 8 \}\}\n        \{\{- end \}\}\n",
                 "      {{- with .Values.podAnnotations }}\n      annotations:\n        {{- toYaml . | nindent 8 }}\n      {{- end }}\n", s, flags=re.S)
assert n == 1 and "checksum" not in new, "annotation block not found"
open(p, "w").write(new)
PY
SH
# ...and the cluster gets it from the CLI (pods roll once, onto the same config).
u="$STATE/scratch/up$N"; rm -rf "$u"; git clone -q "$(repo_url "$REPO")" "$u"
HELM -n "$NS" upgrade "$REL" "$u/chart/demo-api" -f "$u/chart/demo-api/values-staging.yaml" \
  --set image.repository="$REGISTRY/platform-lab/demo-api" --set image.tag="$TAG" \
  --wait --timeout 150s --description "deployment: drop checksum/config" >/dev/null
rm -rf "$u"

# 4. Sam bumps the release label (values only) and deploys it with helm from the repo, the
#    way the release train always did: same chart version, only the ConfigMap changes.
#    (Jenkinsfile.helm cannot show this bug: it packages every build as 0.1.0-build.N, and
#    helm.sh/chart is a pod label, so a pipeline deploy rolls the pods whatever the config did.)
as_teammate "Sam (release train)" "$REPO" "staging: release label 2026.10.2" <<'SH'
sed -i.bak 's/VERSION: "2026.10.1"/VERSION: "2026.10.2"/' chart/demo-api/values-staging.yaml && rm -f chart/demo-api/values-staging.yaml.bak
grep -q '2026.10.2' chart/demo-api/values-staging.yaml
SH
u="$STATE/scratch/up$N"; rm -rf "$u"; git clone -q "$(repo_url "$REPO")" "$u"
HELM -n "$NS" upgrade "$REL" "$u/chart/demo-api" -f "$u/chart/demo-api/values-staging.yaml" \
  --set image.repository="$REGISTRY/platform-lab/demo-api" --set image.tag="$TAG" \
  --wait --timeout 150s --description "staging: release label 2026.10.2 (helm CLI from the release-train repo)" >/dev/null
rm -rf "$u"
job_scm "$TAG"     # the pipeline is there for the fix; nothing has run it yet

# 5. Make sure the incident is what the ticket says.
rev=$(HELM -n "$NS" status "$REL" -o json | jq -r .version)
[[ $rev == 3 ]] || { echo "expected release revision 3, found $rev"; exit 1; }
cm=$(K -n "$NS" get cm "$FULL" -o jsonpath='{.data.VERSION}')
live=$(svc_get / | jq -r .version)
[[ $cm == 2026.10.2 && $live == 2026.10.1 ]] || { echo "expected ConfigMap 2026.10.2 / served 2026.10.1, found $cm / $live"; exit 1; }

printf 'BREAK_REV=%s\nBASE_VER=%s\nV1_UID=%s\nTAG=%s\n' "$rev" 0.1.0 "$V1_UID" "$TAG" > "$SF"
player_clone
