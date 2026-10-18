#!/usr/bin/env bash
# "Deploys take 4 minutes": Sam removes --atomic --wait --timeout from the helm
# upgrade and the Test stage from Jenkinsfile.helm, and moves staging to the
# Recreate strategy. Then someone ships config.FAIL_HEALTH=true "to test the
# alert". Without --wait the pipeline returns when the API accepted the YAML,
# so the build is green, the release is "deployed", Recreate has taken every
# good pod down and the new ones never become Ready.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
leftovers_guard

img=$(K -n demo-ci get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ $img == *:* ]] || { echo "demo-api is not deployed in demo-ci -- run: play reset"; exit 1; }
TAG=${img##*:}

# 1. The repo as the platform team ships it (--atomic --wait --timeout, Test stage), the namespace and the Role.
d="$STATE/scratch/seed$N"
seed_dir "$d" "$TAG"
repo_publish "$d"
apply_rbac "$d"

# 2. Revision 1: the first install, by the book.
HELM -n "$NS" upgrade --install "$REL" "$d/chart/demo-api" -f "$d/chart/demo-api/values-staging.yaml" \
  --set image.repository="$REGISTRY/platform-lab/demo-api" --set image.tag="$TAG" \
  --atomic --wait --timeout 150s --description "first install (helm CLI), chart as imported" >/dev/null
V1_UID=$(K -n "$NS" get secret "sh.helm.release.v1.$REL.v1" -o jsonpath='{.metadata.uid}')
rm -rf "$d"

# 3. Sam's two commits.
as_teammate "Sam (payments)" "$REPO" "values-staging: Recreate strategy (surge pods kept hitting the namespace quota)" <<'SH'
cat >> chart/demo-api/values-staging.yaml <<'EOF2'

# Sam: surge pods hit the namespace quota during rollouts; replace instead of surge.
strategy:
  type: Recreate
  rollingUpdate: null
EOF2
SH
as_teammate "Sam (payments)" "$REPO" "Jenkinsfile.helm: faster deploys (no --atomic/--wait, no helm test); the deploy stage took ~4 min" <<'SH'
python3 - <<'PY'
import re
p = "Jenkinsfile.helm"
s = open(p).read()
old = '                          --atomic --wait --timeout "$TIMEOUT" \\\n'
assert old in s
s = s.replace(old, '')
old2 = '                        if [ -n "$EXTRA_SET" ]; then set -- --set "$EXTRA_SET"; fi\n'
assert old2 in s
s = s.replace(old2, old2 + '                        # Sam: no --atomic/--wait here, the deploy stage took ~4 min and blocked the next build.\n', 1)
s, n = re.subn(r"        stage\('Test'\) \{\n.*?\n        \}\n(?=    \}\n    post \{)", "", s, flags=re.S)
assert n == 1
open(p, "w").write(s)
PY
SH

# 4. The job. Build 1 is Sam's first run of the faster pipeline (a normal deploy: revision 2).
job_scm "$TAG"
out="$STATE/scratch/break$N.console"
job_run "$out" 420 "IMAGE_TAG=$TAG"
[[ $JOB_RESULT == SUCCESS ]] || { echo "run 1 of $JOB ended $JOB_RESULT -- see $JENKINS_URL/job/$JOB/$JOB_NUM/console"; tail -25 "$out"; exit 1; }
K -n "$NS" rollout status "deploy/$FULL" --timeout=120s >/dev/null     # Recreate: let it settle before the next run
[[ $(HELM -n "$NS" status "$REL" -o json | jq -r .version) == 2 ]] || { echo "expected revision 2 after run 1"; exit 1; }

# 5. Build 2: "run it with a flag to test the alert". Green, revision 3 "deployed".
job_run "$out" 420 "IMAGE_TAG=$TAG" "EXTRA_SET=config.FAIL_HEALTH=true"
[[ $JOB_RESULT == SUCCESS ]] || { echo "run 2 of $JOB ended $JOB_RESULT -- see $JENKINS_URL/job/$JOB/$JOB_NUM/console"; tail -25 "$out"; exit 1; }

# 6. Make sure the incident is what the ticket says.
rev=$(HELM -n "$NS" status "$REL" -o json | jq -r .version)
[[ $rev == 3 ]] || { echo "expected release revision 3, found $rev"; exit 1; }
cm=$(K -n "$NS" get cm "$FULL" -o jsonpath='{.data.FAIL_HEALTH}')
[[ $cm == true ]] || { echo "expected FAIL_HEALTH=true in the ConfigMap, found '$cm'"; exit 1; }
eps=99
for _ in $(seq 1 30); do
  eps=$(ready_eps)
  [[ $eps == 0 ]] && break; sleep 2
done
[[ $eps == 0 ]] || { echo "the Service still has $eps ready endpoints; the break did not take"; exit 1; }
rm -f "$out"

printf 'BREAK_REV=%s\nGOOD_REV=%s\nBASE_VER=%s\nV1_UID=%s\nTAG=%s\n' "$rev" 2 0.1.0 "$V1_UID" "$TAG" > "$SF"
player_clone
