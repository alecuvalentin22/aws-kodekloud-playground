#!/usr/bin/env bash
# Reset for the GitHub tier: `play reset` calls this with the drill id;
# `setup/up-github.sh --reset` calls it with none (every drill's reset.sh).
#
# Back to baseline, as NEW COMMITS (main is never force-pushed):
#   - the drill's own reset.sh (state files)
#   - open pull requests closed, every branch but main deleted
#   - demo-api main protection re-applied (admins enforced, no required checks)
#   - each repo's tree on main put back to the `baseline` commit, as a commit
#   - stray tags deleted; `baseline` and `v1.0.0` restored if they were moved
#   - CI on main green again (a fresh run is dispatched if main did not move)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/github.sh"
gh_load_env
id=${1:-}

if [[ -n $id ]]; then
  d=$(find "$PG_ROOT/drills" -maxdepth 1 -type d -name "$id-*" | head -1)
  [[ -n $d ]] || { c_bad "no drill $id"; exit 1; }
  c_hdr "Resetting GitHub drill $id"
  [[ -f $d/reset.sh ]] && { bash "$d/reset.sh" || { c_bad "reset.sh failed"; exit 1; }; }
else
  c_hdr "Resetting the GitHub tier to baseline"
  for d in "$PG_ROOT"/drills/3[1-9]-*/; do [[ -f "$d/reset.sh" ]] && bash "$d/reset.sh" >>"$GH_STATE/logs/reset.log" 2>&1; done
fi

t0=$(date +%s)
moved=""

reset_repo() {   # reset_repo REPO
  local r=$1 base="/repos/$GITHUB_OWNER/$1" dir="$GH_STATE/scratch/reset-$1" n b t bsha cur tags
  gh_exists "$base" || { c_bad "$GITHUB_OWNER/$r is gone. Run: playground/setup/up-github.sh"; return 1; }
  for n in $(gh_api GET "$base/pulls?state=open&per_page=100" | jq -r '.[].number'); do
    gh_api PATCH "$base/pulls/$n" '{"state":"closed"}' >/dev/null && c_ok "$r: closed PR #$n"
  done
  for b in $(gh_api GET "$base/branches?per_page=100" | jq -r '.[].name | select(. != "main")'); do
    gh_api DELETE "$base/git/refs/heads/$b" >/dev/null && c_ok "$r: deleted branch $b"
  done
  if [[ $r == "$GH_APP1" ]]; then gh_protect "$r" && c_ok "$r: main protection back to baseline"; fi

  bsha=$(gh_state_get "baseline-$r")
  [[ -n $bsha ]] || bsha=$(gh_tag_sha "$GITHUB_OWNER" "$r" baseline) || { c_bad "$r: no baseline recorded"; return 1; }
  rm -rf "$dir"
  gh_git clone -q "$(gh_url "$r")" "$dir" || { c_bad "$r: clone failed"; return 1; }
  git -C "$dir" cat-file -e "$bsha^{commit}" 2>/dev/null || gh_git -C "$dir" fetch -q origin "$bsha"

  # Tags: the baseline and (shared repo) v1.0.0 point where they did; nothing else survives.
  cur=$(git -C "$dir" rev-parse -q --verify "refs/tags/baseline^{commit}" 2>/dev/null)
  if [[ $cur != "$bsha" ]]; then
    git -C "$dir" tag -f baseline "$bsha" >/dev/null && gh_git -C "$dir" push -q -f origin refs/tags/baseline && c_ok "$r: tag baseline restored"
  fi
  if [[ $r == "$GH_WF" ]]; then
    cur=$(git -C "$dir" rev-parse -q --verify "refs/tags/v1.0.0^{commit}" 2>/dev/null)
    if [[ $cur != "$(gh_state_get v1.0.0-sha)" ]]; then
      git -C "$dir" tag -f v1.0.0 "$(gh_state_get v1.0.0-sha)" >/dev/null && gh_git -C "$dir" push -q -f origin refs/tags/v1.0.0 && c_ok "$r: tag v1.0.0 restored"
    fi
  fi
  for t in $(git -C "$dir" tag -l); do
    [[ $t == baseline || ( $r == "$GH_WF" && $t == v1.0.0 ) ]] && continue
    gh_git -C "$dir" push -q origin --delete "$t" 2>/dev/null && c_ok "$r: deleted tag $t"
  done

  # Content: a commit that makes the tree equal to the baseline's.
  if [[ $(git -C "$dir" rev-parse 'HEAD^{tree}') != "$(git -C "$dir" rev-parse "$bsha^{tree}")" ]]; then
    git -C "$dir" rm -rq . && git -C "$dir" checkout -q "$bsha" -- . && git -C "$dir" add -A
    git -C "$dir" -c user.name="playground reset" -c user.email=reset@playground.local commit -q -m "reset to baseline"
    gh_push_main "$r" "$dir" || return 1
    moved="$moved $r"
    c_ok "$r: main back to baseline content (a new commit, not a force-push)"
  fi
  rm -rf "$dir"
}

rc=0
for r in $GH_WF $GH_APP1 $GH_APP2; do reset_repo "$r" || rc=1; done
(( rc == 0 )) || exit 1

for r in $GH_APP1 $GH_APP2; do
  sha=$(gh_head "$r" main)
  [[ " $moved " == *" $r "* ]] || gh_dispatch_ci "$r"   # main did not move: make a fresh run to wait for
  printf "  waiting for CI on %s %s " "$r" "${sha:0:7}"
  gh_wait_green "$r" "$sha" "$t0" 600; g=$?
  echo
  case $g in
    0) c_ok "$r: CI green on main" ;;
    1) c_bad "$r: CI is red on the baseline: $(gh_web "$r")/actions"; rc=1 ;;
    *) c_bad "$r: CI did not finish in 10 minutes: $(gh_web "$r")/actions"; rc=1 ;;
  esac
done
(( rc == 0 )) || exit 1

# Bring the candidate's clones along, if that cannot lose anything.
for r in $GH_APP1 $GH_APP2 $GH_WF; do
  c="$GH_WORK/$r"
  [[ -d $c/.git ]] || continue
  gh_git -C "$c" fetch -q --prune --tags -f 2>/dev/null
  if [[ $(git -C "$c" rev-parse --abbrev-ref HEAD) == main && -z $(git -C "$c" status --porcelain) ]]; then
    git -C "$c" merge -q --ff-only origin/main 2>/dev/null && c_ok "$c: main updated" \
      || c_warn "$c: main has local commits; sort it out with: git -C $c fetch && git -C $c status"
  else
    c_warn "$c: not on a clean main; when ready: git -C $c checkout main && git -C $c pull"
  fi
done
c_ok "baseline: 3 repos, main protected, CI green"
