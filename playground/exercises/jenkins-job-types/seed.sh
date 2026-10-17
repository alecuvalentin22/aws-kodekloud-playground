#!/usr/bin/env bash
# Create the tiny repo the exercise builds (payments/jobtypes-demo in the
# playground's Gitea) and a clone of it in ~/platform-playground/jobtypes-demo.
# Idempotent: an existing repo is kept. Run it from the playground box (or the
# Mac that runs the playground).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

if gitea_api GET "/repos/$REPO" >/dev/null 2>&1; then
  c_dim "  $REPO exists, kept"
else
  gitea_api POST /orgs/payments/repos '{"name":"jobtypes-demo","private":false,"description":"Jenkins job-types exercise"}' >/dev/null
  d="$STATE/scratch/seed-jobtypes"; rm -rf "$d"; mkdir -p "$d"
  cp -R "$HERE/app/." "$d/"
  mkdir -p "$d/examples" "$d/jobs"
  cp "$HERE"/examples/*.groovy "$d/examples/"
  cp "$HERE"/jobs/*.groovy "$d/jobs/"
  git -C "$d" init -q -b main
  git -C "$d" add -A
  git -C "$d" -c user.name="Platform team" -c user.email="platform@playground.local" commit -q -m "jobtypes-demo: tiny app + examples"
  git -C "$d" push -q "$(repo_url "$REPO")" main
  rm -rf "$d"
  c_ok "created $REPO"
fi

w="$WORK/jobtypes-demo"
if [[ ! -d $w/.git ]]; then
  cred_file="$STATE/git-credentials"
  git clone -q "http://$GITEA_USER@localhost:30300/$REPO.git" "$w" -c credential.helper="store --file=$cred_file"
  git -C "$w" config user.name "You (platform team)"
  git -C "$w" config user.email "you@playground.local"
fi
c_ok "your clone: $w"
echo "  Jenkins $JENKINS_URL   Gitea $GITEA_URL/$REPO   agent label: $AGENT_LABEL"
