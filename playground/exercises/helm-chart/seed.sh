#!/usr/bin/env bash
# Set up the exercise on the playground:
#   - namespace ex-helm-notes (nothing else uses it)
#   - your working copy ~/platform-playground/notes-api with the service's source
#     (app.py, test_app.py, Dockerfile). YOU add the chart under chart/.
#   - the service's image built and pushed to the playground registry as
#     localhost:5001/helm-lab/notes-api:1.0.0 and :1.1.0
# Idempotent: it keeps what exists. Run it on the machine that runs the playground.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

for t in kubectl helm jq curl docker; do command -v $t >/dev/null || die "$t not on PATH"; done
K get nodes >/dev/null 2>&1 || die "the playground cluster is not reachable (play doctor)"
curl -fsS "http://$REG_HOST/v2/" >/dev/null 2>&1 || die "the playground registry is not reachable at $REG_HOST (play doctor)"

# 1. Namespace.
K create namespace "$NS" --dry-run=client -o yaml | K apply -f - >/dev/null
c_ok "namespace $NS"

# 2. The service's source, in your working copy. Existing files are never overwritten.
mkdir -p "$PROJECT"
for f in app.py test_app.py Dockerfile .dockerignore; do
  [[ -e $PROJECT/$f ]] || cp "$HERE/app/$f" "$PROJECT/$f"
done
c_ok "service source in $PROJECT"

# 3. The image, two tags (the second is for the optional 'new image, same chart' step).
for tag in $IMG_TAGS; do
  if reg_tags "$IMG_REPO" | grep -qx "$tag"; then c_dim "  image $IMG_REPO:$tag already in the registry, kept"; continue; fi
  docker build -q --build-arg VERSION="$tag" -t "$REG_HOST/$IMG_REPO:$tag" "$PROJECT" >/dev/null
  docker push -q "$REG_HOST/$IMG_REPO:$tag" >/dev/null
  c_ok "built and pushed $REG_HOST/$IMG_REPO:$tag   (in the cluster: $REGISTRY/$IMG_REPO:$tag)"
done

cat <<EOT

Ready. Read the README, then work in:  $PROJECT
  cd $PROJECT && python3 -m unittest -q     # the service has tests; the chart is yours
Any time, for a ✓/✗ per step:  $HERE/check.sh
EOT
