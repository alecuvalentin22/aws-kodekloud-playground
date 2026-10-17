#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds

# 1. main is green AFTER the incident started, and what runs is main's HEAD.
assert_main_green_since "$DRILL_STARTED" || exit 1

# 2. The Deployment runs the image THAT build produced. The tag ends in the
#    build number (<branch>-<sha>-<build>), so a deploy that guessed, reused a
#    stale reference or rebuilt something else does not match.
n=$(jq -r '.number' <<<"$(last_build main)")
img=$(K -n demo-ci get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
if [[ $img != *"-$n" ]]; then
  c_bad "demo-api runs $img, which build #$n did not produce (its tag should end in -$n)"; exit 1
fi
c_ok "the Deployment runs exactly what build #$n pushed: $img"

# 3. The image must really be in the registry (the hand-off carried a real reference).
tag=${img##*:}
if ! curl -fsS "$REGISTRY_URL/v2/platform-lab/demo-api/tags/list" 2>/dev/null | jq -e --arg t "$tag" '.tags | index($t)' >/dev/null 2>&1; then
  c_bad "tag $tag is not in the registry"; exit 1
fi
c_ok "$tag is in the registry"

log=$(jenkins_get "/job/demo-api/job/main/lastBuild/consoleText" 2>/dev/null || true)
jf=$(curl -fsS "$GITEA_URL/payments/demo-api/raw/branch/main/Jenkinsfile" 2>/dev/null || true)

# 4. Penalties: fixes that go green but would hurt at work.
if grep -Eq 'hostPath|persistentVolumeClaim|claimName' <<<"$jf"; then
  echo "PENALTY 25 A shared hostPath/PVC as the hand-off: it ties builds to one node, two concurrent builds race on the same path, and files outlive the build. stash/unstash, env or a registry are scoped to the build."
fi
if grep -Eq 'copyArtifacts|/artifact/' <<<"$jf"; then
  echo "PENALTY 20 Archiving to the controller and fetching it back from there is not a hand-off mechanism: archiveArtifacts keeps records for people, it is not an in-build transport (it needs a plugin, a URL and credentials to read it back)."
fi
if (( $(grep -c 'ImageTag.of' <<<"$jf") > 1 )); then
  echo "PENALTY 10 Deploy recomputes the image tag instead of receiving what Build pushed. It matches today; the day the tag rule changes in one place, Deploy deploys something that was never built."
fi
if ! grep -q '(API contract)' <<<"$log"; then
  echo "PENALTY 25 The API contract stage is gone from the pipeline. The team left the golden path for it; you made it green by deleting the reason they needed it."
fi
