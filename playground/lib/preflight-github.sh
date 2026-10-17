#!/usr/bin/env bash
# Is the GitHub tier ready for a drill? `play start` runs this before any drill
# with NEEDS=github. Exits non-zero with ONE line saying what to do.
set -uo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/github.sh"

fail() { c_bad "$*"; exit 1; }

for t in git jq curl; do command -v "$t" >/dev/null || fail "$t is not on PATH."; done
[[ -r "$GH_ENV_FILE" ]] || fail "No GitHub token: create $GH_ENV_FILE (mode 600, GITHUB_TOKEN= and GITHUB_OWNER=); see playground/setup/GITHUB.md."
mode=$(gh__mode "$GH_ENV_FILE")
[[ $mode == 600 || $mode == 400 ]] || fail "$GH_ENV_FILE is mode $mode: chmod 600 it (it holds a token)."
gh_load_env
export GH_QUIET=1
login=$(gh_whoami 2>/dev/null) || fail "GitHub rejects the token in $GH_ENV_FILE (expired or revoked?). Make a new one: GITHUB.md."
[[ $(printf '%s' "$login" | tr '[:upper:]' '[:lower:]') == $(printf '%s' "$GITHUB_OWNER" | tr '[:upper:]' '[:lower:]') ]] \
  || fail "The token is for '$login' but GITHUB_OWNER is '$GITHUB_OWNER'."
left=$(gh_rate_left 2>/dev/null || echo 0)
(( left >= 150 )) || fail "Only $left GitHub API calls left this hour (resets on the hour). A drill needs ~100; wait, then start."

for r in $GH_REPOS; do
  gh_exists "/repos/$GITHUB_OWNER/$r" || fail "$GITHUB_OWNER/$r does not exist. Run: playground/setup/up-github.sh"
  [[ -d "$GH_WORK/$r/.git" ]] || fail "No clone at $GH_WORK/$r. Run: playground/setup/up-github.sh"
done

# Baseline: main protected the way the drills expect, and CI green on both apps.
dig=$(gh_api GET "/repos/$GITHUB_OWNER/$GH_APP1/branches/main/protection" 2>/dev/null | gh_protection_digest)
[[ -n $dig ]] || fail "$GH_APP1 main has no branch protection. Run: playground/play reset"
[[ $(jq -r '.enforce_admins' <<<"$dig") == true && $(jq -r '.contexts | length' <<<"$dig") == 0 ]] \
  || fail "$GH_APP1 main protection is not the baseline (left over from a drill?). Run: playground/play reset"
for r in $GH_APP1 $GH_APP2; do
  sha=$(gh_head "$r" main 2>/dev/null) || fail "Cannot read $r main."
  run=$(gh_latest_run "$r" "$sha" 2>/dev/null)
  [[ -n $run && $run != null ]] || fail "No CI run for $r main (${sha:0:7}). Run: playground/play reset"
  st=$(jq -r '.status' <<<"$run"); co=$(jq -r '.conclusion // "-"' <<<"$run")
  [[ $st == completed ]] || fail "CI on $r main is still $st: wait for it, then start."
  [[ $co == success ]] || fail "CI on $r main is $co, so the baseline is not green. Run: playground/play reset"
done
c_ok "GitHub tier ready: $GITHUB_OWNER, 3 repos, baseline green, $left API calls left"
