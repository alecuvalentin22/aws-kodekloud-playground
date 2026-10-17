#!/usr/bin/env bash
# The GitHub tier of the playground: real GitHub, real Actions, real GHCR, in
# THREE public repos under YOUR account (see GITHUB.md for the token).
#
#   playground/setup/up-github.sh                 create / repair (idempotent)
#   playground/setup/up-github.sh --reset         back to baseline after a drill
#   playground/setup/up-github.sh --destroy [--yes]   delete the playground repos
#   playground/setup/up-github.sh --pin-actions   rewrite `uses: x@vN` in the template to
#                                                 commit SHAs (read-only API calls)
#   playground/setup/up-github.sh --selftest      offline parsing/jq tests, no network
#
# Creates, from playground/github-template/ (never touches the repo this code lives in):
#   playground-workflows    the platform's reusable workflow, tagged v1.0.0
#   playground-demo-api     app repo: CI + image on GHCR, main PROTECTED
#   playground-search-api   a second caller of the shared workflow
# then waits for the baseline CI on main to be green and clones them into
# ~/platform-playground-github. State: ~/.local/state/platform-lab-playground/github.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/../lib/github.sh"
TEMPLATE="$PG_ROOT/github-template"

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# Copy a template dir and fill in the placeholders.
render_template() {   # render_template app|workflows DEST REPO
  local src="$TEMPLATE/$1" dest=$2 repo=$3 lc
  lc=$(printf '%s' "$GITHUB_OWNER" | tr '[:upper:]' '[:lower:]')
  rm -rf "$dest"; mkdir -p "$dest"
  cp -R "$src/." "$dest/"
  find "$dest" -type f -exec sed -i.bak \
    -e "s|__OWNER_LC__|$lc|g" -e "s|__OWNER__|$GITHUB_OWNER|g" \
    -e "s|__REPO__|$repo|g" -e "s|__WORKFLOWS_REPO__|$GH_WF|g" {} +
  find "$dest" -name '*.bak' -type f -delete
}

# Create the repo if missing; refuse one that exists but is not ours.
ensure_repo() {   # ensure_repo REPO "what it is"
  local repo=$1 what=$2 desc
  if gh_exists "/repos/$GITHUB_OWNER/$repo"; then
    desc=$(gh_api GET "/repos/$GITHUB_OWNER/$repo" | jq -r '.description // ""')
    [[ $desc == "$GH_MARK"* ]] || die "$GITHUB_OWNER/$repo exists and is NOT a playground repo (description lacks '$GH_MARK'). Rename or delete it, then re-run."
    c_dim "  $repo exists, kept"
  else
    gh_api POST /user/repos "$(jq -nc --arg n "$repo" --arg d "$GH_MARK: $what (safe to delete)" \
      '{name: $n, description: $d, private: false, auto_init: false, has_wiki: false, has_projects: false}')" >/dev/null
    c_ok "created $GITHUB_OWNER/$repo (public)"
  fi
}

# Push the initial commit if main does not exist yet.
seed_repo() {   # seed_repo REPO TEMPLATE-NAME
  local repo=$1 tpl=$2 dir="$GH_STATE/scratch/seed-$1"
  if [[ -n $(gh_git ls-remote "$(gh_url "$repo")" refs/heads/main 2>/dev/null) ]]; then return 0; fi
  render_template "$tpl" "$dir" "$repo"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  git -C "$dir" add -A
  git -C "$dir" -c user.name="Platform team" -c user.email="platform@playground.local" \
    commit -q -m "Initial import from platform-lab"
  git -C "$dir" tag baseline
  [[ $repo == "$GH_WF" ]] && git -C "$dir" tag v1.0.0
  gh_git -C "$dir" push -q origin main --tags 2>"$GH_STATE/logs/seed-$repo.log" || {
    cat "$GH_STATE/logs/seed-$repo.log" >&2
    die "initial push to $repo failed. A token without the 'workflow' scope cannot push .github/workflows/ (GITHUB.md)."; }
  rm -rf "$dir"
  c_ok "pushed the initial commit to $repo"
}

# Settings every run re-asserts (idempotent).
configure_repo() {   # configure_repo REPO
  local r=$1 base="/repos/$GITHUB_OWNER/$1"
  gh_api PATCH "$base" '{"default_branch":"main","delete_branch_on_merge":true,"allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":true}' >/dev/null
  gh_api PUT "$base/topics" "{\"names\":[\"$GH_TOPIC\"]}" >/dev/null
  gh_api PUT "$base/actions/permissions" '{"enabled":true,"allowed_actions":"all"}' >/dev/null
  # Drill 34 depends on this: GITHUB_TOKEN is read-only unless a job asks for more.
  gh_api PUT "$base/actions/permissions/workflow" '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}' >/dev/null
  [[ -n $(gh_state_get "baseline-$r") ]] || gh_state_set "baseline-$r" "$(gh_tag_sha "$GITHUB_OWNER" "$r" baseline)"
  [[ $r != "$GH_WF" ]] || [[ -n $(gh_state_get "v1.0.0-sha") ]] || gh_state_set "v1.0.0-sha" "$(gh_tag_sha "$GITHUB_OWNER" "$r" v1.0.0)"
}

# Wait for CI on main's head to be green; explain if it is not.
ensure_green() {   # ensure_green REPO
  local r=$1 sha n run rc=0
  sha=$(gh_head "$r" main)
  n=$(gh_api GET "/repos/$GITHUB_OWNER/$r/actions/runs?head_sha=$sha" | jq '.workflow_runs | length')
  if (( n == 0 )); then gh_dispatch_ci "$r"; sleep 5; fi
  printf "  waiting for CI on %s %s " "$r" "${sha:0:7}"
  gh_wait_green "$r" "$sha" $(( $(date +%s) - 2592000 )) 600 || rc=$?
  echo
  case $rc in
    0) c_ok "$r: CI green on main (${sha:0:7})" ;;
    1) run=$(gh_latest_run "$r" "$sha")
       c_bad "$r: CI is RED on main (${sha:0:7}): $(jq -r .html_url <<<"$run")"
       gh_run_jobs "$r" "$(jq -r .id <<<"$run")" | sed 's/^/      /' >&2
       die "the baseline must be green. If a drill left it broken: playground/setup/up-github.sh --reset" ;;
    *) die "$r: no finished CI run after 10 minutes. Check $(gh_web "$r")/actions (Actions disabled? queue?)" ;;
  esac
}

install() {
  c_hdr "0/5 preflight"
  local t; for t in git jq curl; do command -v "$t" >/dev/null || die "$t not on PATH"; done
  gh_load_env
  local login scopes hdr; hdr=$(mktemp "${TMPDIR:-/tmp}/ghhdr.XXXXXX")
  login=$(GH_HDR_OUT="$hdr" gh_whoami) || { rm -f "$hdr"; die "GitHub rejected the token (see above)"; }
  scopes=$(tr -d '\r' < "$hdr" | awk -F': *' 'tolower($1) == "x-oauth-scopes" { print $2 }'); rm -f "$hdr"
  [[ $(printf '%s' "$login" | tr '[:upper:]' '[:lower:]') == $(printf '%s' "$GITHUB_OWNER" | tr '[:upper:]' '[:lower:]') ]] \
    || die "The token belongs to '$login' but GITHUB_OWNER is '$GITHUB_OWNER'. The playground runs on your own user account."
  c_ok "token valid for $login, $(gh_rate_left) API calls left this hour"
  if [[ -z $scopes ]]; then
    c_warn "no X-OAuth-Scopes header: a fine-grained token? It cannot use the packages API (drill 34 check) -- GITHUB.md"
  else
    local need
    for need in repo workflow; do
      [[ ",$(tr -d ' ' <<<"$scopes")," == *",$need,"* ]] || die "token lacks the '$need' scope (has: $scopes). See GITHUB.md"
    done
    for need in read:packages delete_repo delete:packages; do
      [[ ",$(tr -d ' ' <<<"$scopes")," == *",$need,"* ]] || c_warn "token lacks '$need': $(
        case $need in read:packages) echo 'drill 34 cannot check the image';; *) echo '--destroy cannot clean up fully';; esac)"
    done
  fi

  c_hdr "1/5 repositories (public, under $GITHUB_OWNER)"
  ensure_repo "$GH_WF" "reusable workflows"
  ensure_repo "$GH_APP1" "app repo, CI + GHCR image"
  ensure_repo "$GH_APP2" "second caller of the shared workflows"
  seed_repo "$GH_WF" workflows
  seed_repo "$GH_APP1" app
  seed_repo "$GH_APP2" app

  c_hdr "2/5 settings: Actions on, GITHUB_TOKEN read-only by default, branch protection"
  for r in $GH_REPOS; do configure_repo "$r"; done
  gh_protect "$GH_APP1"
  c_ok "$GH_APP1 main: pull request required, admins included, no force-push, no required checks"

  c_hdr "3/5 baseline CI on main"
  ensure_green "$GH_APP1"
  ensure_green "$GH_APP2"
  local sha7; sha7=$(gh_head "$GH_APP1" main); sha7=${sha7:0:7}
  if gh_ghcr_has_tag "$GH_APP1" "sha-$sha7" 2>/dev/null; then c_ok "ghcr.io/$(printf '%s' "$GITHUB_OWNER" | tr '[:upper:]' '[:lower:]')/$GH_APP1:sha-$sha7 exists"
  else c_warn "could not see image tag sha-$sha7 in GHCR (token lacks read:packages, or the package was left over from an earlier playground -- GITHUB.md, 'orphan package')"; fi

  c_hdr "4/5 your workspace: $GH_WORK"
  mkdir -p "$GH_WORK"
  for r in $GH_APP1 $GH_APP2 $GH_WF; do
    if [[ ! -d "$GH_WORK/$r/.git" ]]; then gh_git clone -q "$(gh_url "$r")" "$GH_WORK/$r"; fi
    gh_clone_config "$GH_WORK/$r"
    c_ok "$GH_WORK/$r"
  done

  c_hdr "5/5 done"
  date +%s > "$GH_STATE/installed"
  cat <<EOF

  GitHub tier ready.   playground/play start --tier github     (or: play start 31)
  After a drill:       playground/play reset                    (runs lib/reset-github.sh)
  Remove it all:       playground/setup/up-github.sh --destroy

  Repos     $(gh_web "$GH_APP1")  |  $GH_APP2  |  $GH_WF
  Actions   $(gh_web "$GH_APP1")/actions
  Clones    $GH_WORK   (the token is not in .git/config: a credential helper reads $GH_ENV_FILE)
EOF
}

destroy() {
  gh_load_env
  local r have="" desc yes=${1:-} ans
  for r in $GH_REPOS; do
    if gh_exists "/repos/$GITHUB_OWNER/$r"; then
      desc=$(gh_api GET "/repos/$GITHUB_OWNER/$r" | jq -r '.description // ""')
      [[ $desc == "$GH_MARK"* ]] || die "$GITHUB_OWNER/$r is not a playground repo (description lacks '$GH_MARK'): refusing to delete it."
      have="$have $r"
    fi
  done
  [[ -n $have ]] || { c_ok "no playground repos under $GITHUB_OWNER"; rm -rf "$GH_STATE/scratch"; return 0; }
  c_hdr "This DELETES, on GitHub, for good:"
  for r in $have; do echo "    https://github.com/$GITHUB_OWNER/$r   (and its GHCR package)"; done
  if [[ $yes != --yes ]]; then
    [[ -t 0 ]] || die "not a terminal: pass --yes to confirm"
    read -r -p "  Type your GitHub login ($GITHUB_OWNER) to confirm: " ans
    [[ $ans == "$GITHUB_OWNER" ]] || die "not confirmed"
  fi
  for r in $have; do
    gh_api DELETE "/repos/$GITHUB_OWNER/$r" >/dev/null && c_ok "deleted $r"
    # A package outlives its repo, and an orphan blocks the next playground's GITHUB_TOKEN from pushing to it.
    GH_QUIET=1 gh_api DELETE "/user/packages/container/$r" >/dev/null && c_ok "deleted package $r" || true
  done
  for r in $GH_REPOS; do
    if gh_exists "/user/packages/container/$r"; then
      c_warn "package $r still exists (token needs delete:packages): delete it at https://github.com/settings/packages"
    fi
  done
  rm -rf "$GH_STATE/scratch"; rm -f "$GH_STATE"/baseline-* "$GH_STATE"/v1.0.0-sha "$GH_STATE"/drill* "$GH_STATE/installed" "$GH_STATE/current.env"
  c_ok "state cleared. Your clones in $GH_WORK are left alone: delete them yourself if you want."
}

# Rewrite `uses: owner/repo@vN` in the template to a full commit SHA, keeping
# the tag in a comment. Read-only against GitHub; changes files in THIS repo.
pin_actions() {
  gh_load_env
  local refs r slug tag sha n=0 files
  files=$(find "$TEMPLATE" -name '*.yml' -type f)
  # shellcheck disable=SC2086
  refs=$(grep -hoE 'uses: *[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@v[0-9][0-9A-Za-z.]*' $files | sed -E 's/uses: *//' | sort -u) || true
  [[ -n $refs ]] || { c_ok "nothing to pin (already SHAs?)"; return 0; }
  for r in $refs; do
    slug=${r%@*}; tag=${r#*@}
    if sha=$(gh_tag_sha "${slug%/*}" "${slug#*/}" "$tag") && [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
      # shellcheck disable=SC2086
      find "$TEMPLATE" -name '*.yml' -type f -exec sed -i.bak -E "s|(uses: *$slug)@$tag[[:space:]]*\$|\1@$sha # $tag|" {} +
      find "$TEMPLATE" -name '*.bak' -type f -delete
      c_ok "$slug@$tag -> $sha"; n=$(( n + 1 ))
    else
      c_bad "could not resolve $slug@$tag; left as is"
    fi
  done
  echo "  pinned $n. Review with: git -C $LAB_ROOT diff playground/github-template"
  echo "  Existing playground repos keep the old workflows: --destroy and re-run to get the pinned ones."
}

[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0   # sourced (by a test): functions only
case "${1:-}" in
  "") install ;;
  --selftest) set +e +o pipefail; gh_selftest ;;
  --reset) exec "$PG_ROOT/lib/reset-github.sh" ;;
  --destroy) destroy "${2:-}" ;;
  --pin-actions) pin_actions ;;
  -h|--help) usage ;;
  *) usage; exit 2 ;;
esac
