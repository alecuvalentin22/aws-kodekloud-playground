#!/usr/bin/env bash
# Seed Gitea with the two repos a company would have, copied from this lab:
#
#   platform/platform-lib   <- ci/shared-library   (the platform team's library)
#   payments/demo-api       <- ci/apps/demo-api    (an app team's service)
#
# Tags the library v1.0.0 and both repos `baseline`, which is what
# `play reset` returns to. Skips a repo that already exists unless --force.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_creds
FORCE=${1:-}

seed() {   # seed <org/repo> <source dir> [post-copy fn]
  local repo=$1 src=$2 post=${3:-} dir
  if [[ $FORCE != --force ]] && gitea_api GET "/repos/$repo" >/dev/null 2>&1; then
    c_dim "  $repo exists, kept"; return
  fi
  dir="$STATE/scratch/seed-$(echo "$repo" | tr / _)"
  rm -rf "$dir" && mkdir -p "$dir"
  rsync -a --exclude .pytest_cache --exclude __pycache__ --exclude '*.pyc' "$src/" "$dir/"
  [[ -n $post ]] && (cd "$dir" && $post)
  git -C "$dir" init -q -b main
  git -C "$dir" add -A
  git -C "$dir" -c user.name="Platform team" -c user.email="platform@playground.local" \
    commit -q -m "Initial import from platform-lab"
  git -C "$dir" tag baseline
  [[ $repo == platform/platform-lib ]] && git -C "$dir" tag v1.0.0
  git -C "$dir" push -q --force "$(repo_url "$repo")" main --tags
  rm -rf "$dir"
  c_ok "seeded $repo"
}

app_post() {
  # The app repo has its own root, so context is '.', and the registry comes
  # from the Jenkins instance (PLATFORM_REGISTRY), never from the team.
  cat > Jenkinsfile <<'EOF'
// The whole Jenkinsfile. Everything else -- the agent pod, tests, the image
// build and push, the deploy and its rollback -- lives in platform-lib.
@Library('platform-lib') _

standardPipeline(
    app:     'demo-api',
    context: '.',
)
EOF
  cat > README.md <<'EOF'
# demo-api (payments team)

Flask service, built and deployed by the platform team's `platform-lib`
Jenkins library. Pushing to `main` deploys to namespace `demo-ci`.
EOF
}

seed platform/platform-lib "$LAB_ROOT/ci/shared-library"
seed payments/demo-api "$LAB_ROOT/ci/apps/demo-api" app_post
