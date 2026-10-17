# shellcheck shell=bash
# The GitHub tier. Source AFTER lib/common.sh. Plain curl + jq against the
# GitHub REST API: no `gh` CLI needed.
#
#   source lib/common.sh; source lib/github.sh; gh_load_env
#
# Drills run against the CANDIDATE'S OWN GitHub account, in three PUBLIC repos
# created from playground/github-template/ (public: branch protection needs a
# paid plan on private repos, and Actions minutes are free on public ones):
#
#   playground-workflows    the shared/reusable workflows (the "platform" repo)
#   playground-demo-api     an app repo (CI -> GHCR image), main is PROTECTED
#   playground-search-api   a second caller of the shared workflows
#
# The token lives in ~/.config/platform-lab/github-playground.env (mode 600):
#   GITHUB_TOKEN=ghp_...      GITHUB_OWNER=<your login>
# It is read by this file and by lib/git-credential-github.sh ONLY. It is never
# printed, never put in a URL, never in argv (curl gets it through a -K config
# read from a pipe; git gets it through a credential helper).
#
# Own state, so the other tiers' scores/creds/scratch are untouched:
#   STATE  ~/.local/state/platform-lab-playground/github
#   WORK   ~/platform-playground-github        (YOUR clones -- work here)
#
# Self-test (no network):  playground/setup/up-github.sh --selftest

GH_ENV_FILE="${GITHUB_PLAYGROUND_ENV:-$HOME/.config/platform-lab/github-playground.env}"
GH_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GH_STATE="${GITHUB_PLAYGROUND_STATE:-$HOME/.local/state/platform-lab-playground/github}"
GH_WORK="${GITHUB_PLAYGROUND_WORK:-$HOME/platform-playground-github}"
STATE="$GH_STATE"
WORK="$GH_WORK"

# The three repos. Fixed names with a prefix, so a playground repo can never
# be mistaken for (or collide with) one of the candidate's own, and a marker
# in the description + a topic, which --destroy insists on.
GH_WF=playground-workflows
GH_APP1=playground-demo-api
GH_APP2=playground-search-api
GH_REPOS="$GH_WF $GH_APP1 $GH_APP2"
GH_MARK="platform-lab playground"
GH_TOPIC=platform-lab-playground
GH_CRED_HELPER="$PG_ROOT/lib/git-credential-github.sh"

mkdir -p "$GH_STATE/scratch" "$GH_STATE/logs" 2>/dev/null && chmod 700 "$GH_STATE" 2>/dev/null

# --- the token -----------------------------------------------------------------

# KEY=value lines only, parsed (never sourced: nothing in the file is executed).
gh__envval() {   # gh__envval KEY
  awk -v k="$1" '{ sub(/^[ \t]+/, ""); sub(/^export[ \t]+/, "") }
    index($0, k "=") == 1 { sub(/^[^=]*=/, ""); v = $0 }
    END { print v }' "$GH_ENV_FILE" \
    | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

gh__mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }   # GNU || BSD

gh_load_env() {
  [[ -r "$GH_ENV_FILE" ]] || die "No GitHub playground token. Create $GH_ENV_FILE (mode 600) with GITHUB_TOKEN= and GITHUB_OWNER= -- see playground/setup/GITHUB.md"
  local mode; mode=$(gh__mode "$GH_ENV_FILE")
  [[ $mode == 600 || $mode == 400 ]] || die "$GH_ENV_FILE is mode $mode; it holds a token. chmod 600 $GH_ENV_FILE"
  GITHUB_TOKEN=$(gh__envval GITHUB_TOKEN)
  GITHUB_OWNER=$(gh__envval GITHUB_OWNER)
  [[ -n $GITHUB_TOKEN ]] || die "GITHUB_TOKEN is empty in $GH_ENV_FILE"
  [[ -n $GITHUB_OWNER ]] || die "GITHUB_OWNER is empty in $GH_ENV_FILE (your GitHub login)"
  # Not exported on purpose: children (git, drills' python) never inherit it.
}

# Overrides common.sh's load_creds so shared code paths keep working.
load_creds() { gh_load_env; }

# curl reads this as a config file from a pipe: the token is never in argv.
gh__authcfg() {
  printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN"
  printf 'header = "User-Agent: platform-lab-playground"\n'
}

# --- the API ---------------------------------------------------------------------

gh__hdr() { tr -d '\r' < "$1" | awk -F': *' -v k="$2" 'tolower($1) == k { print $2; exit }'; }

# Seconds to wait if this response was a rate limit (primary or secondary),
# 0 if it was not. gh__wait_secs HEADERFILE BODYFILE NOW
gh__wait_secs() {
  local ra rem reset msg w
  ra=$(gh__hdr "$1" retry-after)
  if [[ $ra =~ ^[0-9]+$ ]]; then echo $(( ra + 1 )); return; fi
  rem=$(gh__hdr "$1" x-ratelimit-remaining); reset=$(gh__hdr "$1" x-ratelimit-reset)
  if [[ $rem == 0 && $reset =~ ^[0-9]+$ ]]; then
    w=$(( reset - $3 + 1 )); (( w < 1 )) && w=1; echo "$w"; return
  fi
  msg=$(jq -r '.message // ""' "$2" 2>/dev/null)
  case $msg in *"secondary rate limit"* | *"abuse detection"*) echo 60; return ;; esac
  echo 0
}

# gh_api METHOD PATH [JSON]
#   body -> stdout. rc 0 = 2xx, 4 = 404, 1 = anything else (message on stderr,
#   unless GH_QUIET=1). Retries 5xx and network errors twice; sleeps through a
#   rate limit if the wait is <= GH_MAX_WAIT (90s), otherwise says when it ends.
#   Mutations are spaced GH_MUTATE_DELAY (1s): GitHub's guidance, and it keeps
#   the secondary rate limit away.
#   GH_ACCEPT overrides the Accept header; GH_HDR_OUT=<file> keeps the headers.
gh_api() {
  local m=$1 p=$2 d=${3:-} body hdr code tries=0 w rc=1 msg
  local accept="${GH_ACCEPT:-application/vnd.github+json}"
  [[ -n ${GITHUB_TOKEN:-} ]] || gh_load_env
  body=$(mktemp "${TMPDIR:-/tmp}/ghapi.XXXXXX") || return 1
  hdr=$(mktemp "${TMPDIR:-/tmp}/ghapi.XXXXXX") || return 1
  if [[ $m != GET && ${GH_MUTATE_DELAY:-1} != 0 ]]; then sleep "${GH_MUTATE_DELAY:-1}"; fi
  while :; do
    tries=$(( tries + 1 ))
    if [[ -n $d ]]; then
      code=$(curl -sS -o "$body" -D "$hdr" -w '%{http_code}' -K <(gh__authcfg) -X "$m" \
        -H "Accept: $accept" -H 'X-GitHub-Api-Version: 2022-11-28' -H 'Content-Type: application/json' \
        --data-binary "$d" "$GH_API_URL$p") || code=000
    else
      code=$(curl -sS -o "$body" -D "$hdr" -w '%{http_code}' -K <(gh__authcfg) -X "$m" \
        -H "Accept: $accept" -H 'X-GitHub-Api-Version: 2022-11-28' "$GH_API_URL$p") || code=000
    fi
    if [[ $code == 2?? ]]; then
      cat "$body"; rc=0; break
    fi
    if [[ $code == 000 || $code == 5?? ]]; then
      if (( tries < 3 )); then sleep $(( tries * ${GH_RETRY_SLEEP:-2} )); continue; fi
    fi
    if [[ $code == 403 || $code == 429 ]]; then
      w=$(gh__wait_secs "$hdr" "$body" "$(date +%s)")
      if (( w > 0 )); then
        if (( w <= ${GH_MAX_WAIT:-90} && tries < 4 )); then
          c_warn "GitHub rate limit: waiting ${w}s" >&2; sleep "$w"; continue
        fi
        [[ ${GH_QUIET:-0} == 1 ]] || c_bad "GitHub rate limit: resets in ${w}s. Wait, then run the command again." >&2
        break
      fi
    fi
    [[ $code == 404 ]] && rc=4
    if [[ ${GH_QUIET:-0} != 1 ]]; then
      msg=$(jq -r '[.message // empty, (.errors // [] | map(if type == "object" then (.message // .code // "") else tostring end) | join("; "))] | map(select(. != "")) | join(" -- ")' "$body" 2>/dev/null)
      c_bad "GitHub $m $p -> $code: ${msg:-no message}" >&2
      case $code in
        401) c_dim "    the token is rejected: expired, revoked, or wrong. Edit $GH_ENV_FILE" >&2 ;;
        403) [[ $msg == *"not accessible"* ]] && c_dim "    the token lacks a scope for this call (see playground/setup/GITHUB.md)" >&2 ;;
      esac
    fi
    break
  done
  [[ -n ${GH_HDR_OUT:-} ]] && cp "$hdr" "$GH_HDR_OUT" 2>/dev/null
  rm -f "$body" "$hdr"
  return $rc
}

gh_exists() { GH_QUIET=1 gh_api GET "$1" >/dev/null; }   # 0 yes, 4 no (404), 1 error

# The Nth page of a list endpoint, all pages concatenated into one JSON array.
gh_paginate() {   # gh_paginate PATH   (PATH may already contain ?query)
  local p=$1 sep="?" page=1 out="[]" chunk
  [[ $p == *\?* ]] && sep="&"
  while (( page <= 10 )); do
    chunk=$(gh_api GET "${p}${sep}per_page=100&page=$page") || return 1
    out=$(jq -c -s '.[0] + .[1]' <(echo "$out") <(echo "$chunk"))
    (( $(jq 'length' <<<"$chunk") < 100 )) && break
    page=$(( page + 1 ))
  done
  echo "$out"
}

gh_whoami() { gh_api GET /user | jq -r .login; }
gh_rate_left() { gh_api GET /rate_limit | jq -r '.resources.core.remaining'; }

# --- state -------------------------------------------------------------------------

gh_state_set() { printf '%s\n' "$2" > "$GH_STATE/$1"; }
gh_state_get() { cat "$GH_STATE/$1" 2>/dev/null || true; }
gh_state_rm()  { rm -f "$GH_STATE/$1"; }

# --- git, without the token in any URL or config -------------------------------------

# Clear every other credential helper (a Mac keychain would otherwise STORE
# the token), then ours: it reads the env file and answers only for github.com.
gh_git() { GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c "credential.helper=$GH_CRED_HELPER" "$@"; }
gh_url() { echo "${GH_GIT_BASE:-https://github.com/$GITHUB_OWNER}/$1.git"; }   # GH_GIT_BASE: test hook (a local dir of bare repos)
gh_web() { echo "https://github.com/$GITHUB_OWNER/${1:-}"; }

# Make a clone use the same helper, so `git push` just works for the candidate.
gh_clone_config() {   # gh_clone_config DIR
  git -C "$1" config --unset-all credential.helper 2>/dev/null
  git -C "$1" config --add credential.helper ""
  git -C "$1" config --add credential.helper "$GH_CRED_HELPER"
  git -C "$1" config user.name "You (platform team)"
  git -C "$1" config user.email "you@playground.local"
}

# --- branch protection -----------------------------------------------------------------

# The baseline: changes to main go through a pull request (0 approvals -- she is
# the only human), admins included, no force-push, no deletion, and NO required
# status checks (drill 32 adds one that has gone stale).
# gh__protect_json [required-check-context ...]
gh__protect_json() {
  local ctx="[]"
  if [[ $# -gt 0 ]]; then ctx=$(printf '%s\n' "$@" | jq -R . | jq -sc .); fi
  jq -nc --argjson c "$ctx" '{
    required_status_checks: (if ($c | length) > 0 then {strict: false, checks: ($c | map({context: .}))} else null end),
    enforce_admins: true,
    required_pull_request_reviews: {required_approving_review_count: 0, dismiss_stale_reviews: false, require_code_owner_reviews: false},
    restrictions: null, required_linear_history: false, allow_force_pushes: false, allow_deletions: false,
    required_conversation_resolution: false }'
}
gh_protect() {   # gh_protect REPO [required-check-context ...]
  local r=$1; shift
  gh_api PUT "/repos/$GITHUB_OWNER/$r/branches/main/protection" "$(gh__protect_json "$@")" >/dev/null
}
# enforce_admins off lets the OWNER (the harness's teammate) push to a protected
# main, exactly as an admin bypass would. Always switched back on.
gh_enforce_admins() {   # gh_enforce_admins REPO on|off
  if [[ $2 == on ]]; then gh_api POST "/repos/$GITHUB_OWNER/$1/branches/main/protection/enforce_admins" >/dev/null
  else gh_api DELETE "/repos/$GITHUB_OWNER/$1/branches/main/protection/enforce_admins" >/dev/null; fi
}
# {enforce_admins, contexts[], pr_required, force_push} from a protection JSON on stdin.
gh_protection_digest() {
  jq -c '{enforce_admins: (.enforce_admins.enabled // false),
          contexts: (([.required_status_checks.contexts[]?] + [.required_status_checks.checks[]?.context]) | unique),
          pr_required: (.required_pull_request_reviews != null),
          force_push: (.allow_force_pushes.enabled // false)}'
}

# Push DIR's HEAD to origin main. If main is protected WITH enforce_admins, that
# is switched off for the push and back on right after (the owner's admin bypass,
# which is what a "teammate" or the reset needs).   gh_push_main REPO DIR
gh_push_main() {
  local repo=$1 dir=$2 toggled=0 rc=0
  if GH_QUIET=1 gh_api GET "/repos/$GITHUB_OWNER/$repo/branches/main/protection" \
       | jq -e '.enforce_admins.enabled == true' >/dev/null 2>&1; then
    gh_enforce_admins "$repo" off || return 1
    toggled=1
  fi
  gh_git -C "$dir" push -q origin HEAD:refs/heads/main 2>"$GH_STATE/logs/push-$repo.log" || rc=$?
  (( toggled )) && gh_enforce_admins "$repo" on
  (( rc == 0 )) || { c_bad "push to $repo main failed: $(tail -3 "$GH_STATE/logs/push-$repo.log")" >&2; return 1; }
}

# --- teammates ----------------------------------------------------------------------------

# Push a change as a TEAMMATE would: from a scratch clone, different author, so
# the candidate has to `git pull` and read the log. The script on stdin runs
# inside the clone (bash -e). On a protected main, enforce_admins is switched off
# for the push and back on right after.
#   gh_as_teammate REPO "Sam (payments)" "commit message" [BRANCH]   <<'SH' ... SH
# BRANCH other than main: created from main, pushed there (for a pull request).
# The pushed commit's sha is left in GH_LAST_SHA (a global: call it directly, not in $(...)).
gh_as_teammate() {
  local repo=$1 who=$2 msg=$3 branch=${4:-main} dir script sha
  script=$(cat)
  dir="$GH_STATE/scratch/teammate-$repo"
  rm -rf "$dir"
  gh_git clone -q "$(gh_url "$repo")" "$dir" || { c_bad "clone of $repo failed" >&2; return 1; }
  [[ $branch == main ]] || git -C "$dir" checkout -q -b "$branch"
  ( cd "$dir" && bash -euo pipefail -c "$script" ) || { c_bad "teammate edit failed" >&2; return 1; }
  git -C "$dir" add -A
  if git -C "$dir" diff --cached --quiet; then c_bad "teammate edit changed nothing" >&2; return 1; fi
  git -C "$dir" -c user.name="$who" -c user.email="teammate@playground.local" commit -q -m "$msg"
  if [[ $branch == main ]]; then
    gh_push_main "$repo" "$dir" || return 1
  else
    gh_git -C "$dir" push -q origin "HEAD:refs/heads/$branch" 2>"$GH_STATE/logs/push-$repo.log" \
      || { c_bad "teammate push to $repo failed: $(tail -3 "$GH_STATE/logs/push-$repo.log")" >&2; return 1; }
  fi
  GH_LAST_SHA=$(git -C "$dir" rev-parse HEAD)
  rm -rf "$dir"
}

# gh_open_pr REPO HEAD TITLE BODY  -> PR number
gh_open_pr() {
  gh_api POST "/repos/$GITHUB_OWNER/$1/pulls" \
    "$(jq -nc --arg h "$2" --arg t "$3" --arg b "$4" '{head: $h, base: "main", title: $t, body: $b}')" | jq -r .number
}

gh_dispatch_ci() {   # gh_dispatch_ci REPO   (ci.yml has workflow_dispatch)
  gh_api POST "/repos/$GITHUB_OWNER/$1/actions/workflows/ci.yml/dispatches" '{"ref":"main"}' >/dev/null
}

# --- reading CI state ----------------------------------------------------------------------

gh_head() { gh_api GET "/repos/$GITHUB_OWNER/$1/commits/${2:-main}" | jq -r .sha; }

# The file at a ref, as text.
gh_file() {   # gh_file REPO PATH [REF]
  GH_ACCEPT=application/vnd.github.raw gh_api GET "/repos/$GITHUB_OWNER/$1/contents/$2?ref=${3:-main}"
}

# Newest run of ci.yml for a sha (JSON, or "null"); optional event filter.
gh_latest_run() {   # gh_latest_run REPO SHA [EVENT]
  gh_api GET "/repos/$GITHUB_OWNER/$1/actions/runs?head_sha=$2&per_page=30" \
    | jq -c --arg ev "${3:-}" '[.workflow_runs[]
        | select(((.path // "") | startswith(".github/workflows/ci.yml")) or .name == "CI")
        | select($ev == "" or .event == $ev)] | sort_by(.created_at) | last'
}

# "<runs since ISO> <not finished> <finished but not success>" from a runs list on stdin.
gh_runs_summary() {   # gh_runs_summary SINCE_ISO
  jq -r --arg iso "$1" '[.workflow_runs[] | select(.created_at >= $iso)] as $r
    | "\($r | length) \([$r[] | select(.status != "completed")] | length) \([$r[] | select(.status == "completed" and .conclusion != "success")] | length)"'
}

gh__iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }   # GNU || BSD

# Wait until every run for SHA created since SINCE (epoch) has finished.
#   0 all green   1 one failed   2 nothing finished in time
gh_wait_green() {   # gh_wait_green REPO SHA SINCE_EPOCH [TIMEOUT_S]
  local repo=$1 sha=$2 since=$3 limit=${4:-480} iso t0 runs n pending bad
  iso=$(gh__iso $(( since - 30 ))); t0=$(date +%s)
  while (( $(date +%s) - t0 < limit )); do
    runs=$(gh_api GET "/repos/$GITHUB_OWNER/$repo/actions/runs?head_sha=$sha&per_page=30") || return 2
    read -r n pending bad < <(gh_runs_summary "$iso" <<<"$runs")
    (( bad > 0 )) && return 1
    (( n > 0 && pending == 0 )) && return 0
    sleep "${GH_POLL:-8}"
  done
  return 2
}

# name<TAB>status<TAB>conclusion for every check run on a commit.
gh_check_runs() {   # gh_check_runs REPO SHA
  gh_api GET "/repos/$GITHUB_OWNER/$1/commits/$2/check-runs?per_page=100" \
    | jq -r '.check_runs[] | [.name, .status, (.conclusion // "-")] | @tsv'
}

# The jobs of one run: name<TAB>conclusion.
gh_run_jobs() {   # gh_run_jobs REPO RUN_ID
  gh_api GET "/repos/$GITHUB_OWNER/$1/actions/runs/$2/jobs?per_page=100" \
    | jq -r '.jobs[] | [.name, (.conclusion // .status)] | @tsv'
}

# {state, merged, head, mergeable, mergeable_state} from a PR JSON on stdin.
gh_pr_digest() { jq -c '{state, merged: (.merged // false), head: .head.sha, mergeable, mergeable_state}'; }

# GitHub computes mergeability lazily: `mergeable` is null for a moment.
gh_pr_mergeable() {   # gh_pr_mergeable REPO NUMBER -> digest JSON
  local i d
  for i in 1 2 3 4 5 6; do
    d=$(gh_api GET "/repos/$GITHUB_OWNER/$1/pulls/$2" | gh_pr_digest) || return 1
    [[ $(jq -r '.mergeable' <<<"$d") != null || $(jq -r '.state' <<<"$d") != open ]] && break
    sleep 3
  done
  echo "$d"
}

# Does package REPO have a container version tagged TAG?  (needs read:packages)
gh_ghcr_tags() {   # gh_ghcr_tags PACKAGE -> one tag per line
  gh_api GET "/user/packages/container/$1/versions?per_page=100" | jq -r '.[].metadata.container.tags[]?'
}
gh_ghcr_has_tag() { gh_ghcr_tags "$1" | grep -qx "$2"; }

# Full commit sha of a tag (lightweight or annotated).
gh_tag_sha() {   # gh_tag_sha OWNER REPO TAG
  local ref type sha
  ref=$(GH_QUIET=1 gh_api GET "/repos/$1/$2/git/ref/tags/$3") || return 1
  type=$(jq -r .object.type <<<"$ref"); sha=$(jq -r .object.sha <<<"$ref")
  if [[ $type == tag ]]; then sha=$(gh_api GET "/repos/$1/$2/git/tags/$sha" | jq -r .object.sha); fi
  echo "$sha"
}

# --- reading workflow YAML without a YAML parser -----------------------------------------------
# Heuristics for the block style GitHub's own docs use (2-space indent). They
# are what the checks read; a pathological layout can fool them, which is why
# the checks lean on the API (runs, check runs, protection) wherever they can.

# scope<TAB>key<TAB>value for every `permissions:` entry. scope = top | job:<name>.
# `permissions: write-all` gives key "*".
gh_wf_permissions() {
  awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    { l = $0; sub(/[ \t]+#.*$/, "", l)
      if (l ~ /^[ \t]*(#.*)?$/) next
      i = ind(l); t = l; sub(/^ +/, "", t)
      if (inperm && i <= pind) inperm = 0
      if (inperm) { k = t; sub(/:.*$/, "", k); v = t; sub(/^[^:]*:[ \t]*/, "", v); print scope "\t" k "\t" v; next }
      if (i == 0) {
        section = ""
        if (t ~ /^jobs:/) { section = "jobs"; jind = -1; cind = -1; job = "" }
        else if (t ~ /^permissions:/) {
          v = t; sub(/^permissions:[ \t]*/, "", v)
          if (v != "") print "top\t*\t" v; else { inperm = 1; pind = 0; scope = "top" }
        }
        next
      }
      if (section == "jobs") {
        if (jind < 0) jind = i
        if (i == jind) { job = t; sub(/:.*$/, "", job); cind = -1; next }
        if (cind < 0) cind = i
        if (i == cind && t ~ /^permissions:/) {
          v = t; sub(/^permissions:[ \t]*/, "", v)
          if (v != "") print "job:" job "\t*\t" v; else { inperm = 1; pind = i; scope = "job:" job }
        }
      }
    }'
}

# The lines under `on: <event>:`. First line is "EVENT <event>" when the
# workflow listens to it (also for `on: [push, pull_request]` and `on: pull_request`),
# followed by the event's own keys (paths:, branches:, ...) with relative indent.
gh_wf_event_block() {   # gh_wf_event_block EVENT   (YAML on stdin)
  awk -v ev="$1" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    { l = $0; sub(/[ \t]+#.*$/, "", l)
      if (l ~ /^[ \t]*(#.*)?$/) next
      i = ind(l); t = l; sub(/^ +/, "", t)
      if (i == 0) {
        inon = (t ~ /^"?on"?:/); evind = -1; inev = 0
        if (inon) { rest = t; sub(/^"?on"?:[ \t]*/, "", rest); if (rest != "") flow = rest }
        next }
      if (!inon) next
      if (evind < 0) evind = i
      if (i == evind) {
        inev = (t ~ ("^" ev ":"))
        if (inev) { found = 1; print "EVENT " ev; rest = t; sub("^" ev ":[ \t]*", "", rest); if (rest != "") print " " rest }
        next }
      if (inev) { pad = ""; for (n = 0; n < i - evind; n++) pad = pad " "; print pad t }
    }
    END { if (!found && flow ~ ("(^|[^a-z_])" ev "([^a-z_]|$)")) print "EVENT " ev " (flow style)" }'
}

# The refs a workflow file uses a reusable workflow of REPO at (one per line).
gh_uses_refs() {   # gh_uses_refs REPO   (YAML on stdin)
  sed -nE 's/^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*[^[:space:]@/]+\/'"$1"'\/[^@[:space:]]+@([^[:space:]#]+).*/\2/p'
}
# sha | tag | branch
gh_ref_kind() {
  if [[ $1 =~ ^[0-9a-f]{40}$ ]]; then echo sha
  elif [[ $1 =~ ^v?[0-9]+(\.[0-9]+){0,2}([-+.][0-9A-Za-z.]+)?$ ]]; then echo tag
  else echo branch; fi
}

# --- offline self-test --------------------------------------------------------------------------

gh_selftest() {
  local t fails=0 d out
  t=$(mktemp -d "${TMPDIR:-/tmp}/ghselftest.XXXXXX")
  ok() { c_ok "$1"; }
  no() { c_bad "$1"; fails=$(( fails + 1 )); }
  eq() { if [[ $2 == "$3" ]]; then ok "$1"; else no "$1: wanted [$3] got [$2]"; fi; }

  c_hdr "env file: parsed, never executed; mode enforced"
  GH_ENV_FILE="$t/env"
  printf '# c\nexport GITHUB_TOKEN="ghp_selftest123"\nGITHUB_OWNER=octo-cat ; touch %s/PWNED\n' "$t" > "$GH_ENV_FILE"
  chmod 600 "$GH_ENV_FILE"
  GITHUB_TOKEN=; GITHUB_OWNER=
  ( gh_load_env; [[ $GITHUB_TOKEN == ghp_selftest123 ]] ) && ok "token parsed (quotes and export stripped)" || no "token parse"
  [[ ! -e $t/PWNED ]] && ok "nothing in the file was executed" || no "env file was executed"
  chmod 644 "$GH_ENV_FILE"
  out=$( ( gh_load_env ) 2>&1 ) && no "mode 644 accepted" || ok "mode 644 refused"
  chmod 600 "$GH_ENV_FILE"; GITHUB_TOKEN=ghp_selftest123; GITHUB_OWNER=octo-cat

  c_hdr "curl config carries the token, argv does not"
  [[ $(gh__authcfg) == *"Bearer ghp_selftest123"* ]] && ok "token goes through the -K config" || no "authcfg"

  c_hdr "rate limit parsing"
  printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: 1000\r\n\r\n' > "$t/h1"; echo '{"message":"API rate limit exceeded"}' > "$t/b1"
  eq "primary limit: wait until reset+1" "$(gh__wait_secs "$t/h1" "$t/b1" 940)" 61
  printf 'HTTP/2 403\r\nretry-after: 30\r\n\r\n' > "$t/h2"
  eq "retry-after header wins" "$(gh__wait_secs "$t/h2" "$t/b1" 940)" 31
  printf 'HTTP/2 403\r\nx-ratelimit-remaining: 4000\r\n\r\n' > "$t/h3"; echo '{"message":"Resource not accessible by personal access token"}' > "$t/b3"
  eq "a permissions 403 is not a rate limit" "$(gh__wait_secs "$t/h3" "$t/b3" 940)" 0
  echo '{"message":"You have exceeded a secondary rate limit."}' > "$t/b4"
  eq "secondary limit: 60s" "$(gh__wait_secs "$t/h3" "$t/b4" 940)" 60

  c_hdr "gh_api against a fake curl (retries, 404, rate limit, no token in argv)"
  curl() {   # fake: GH_FAKE_SEQ="code code ..." scripts the status codes; the call count lives in a file
    local o="" D="" i=0 n code
    local -a args=("$@") seq
    while (( i < ${#args[@]} )); do
      case ${args[$i]} in -o) o=${args[$((i + 1))]};; -D) D=${args[$((i + 1))]};; esac
      i=$(( i + 1 ))
    done
    echo "$*" > "$t/argv"
    n=$(cat "$t/n"); seq=($GH_FAKE_SEQ)
    code=${seq[$n]:-200}; echo $(( n + 1 )) > "$t/n"
    printf '%s' "$GH_FAKE_BODY" > "$o"
    printf 'HTTP/2 %s\r\n%b\r\n' "$code" "$GH_FAKE_HDRS" > "$D"
    printf '%s' "$code"
  }
  fake() { echo 0 > "$t/n"; GH_FAKE_SEQ=$1; GH_FAKE_BODY=$2; GH_FAKE_HDRS=${3:-}; }
  GH_MUTATE_DELAY=0; GH_RETRY_SLEEP=0; GH_QUIET=1
  fake "200" '{"login":"octo-cat"}'
  eq "200 returns the body" "$(gh_api GET /user | jq -r .login)" octo-cat
  grep -q ghp_selftest123 "$t/argv" && no "TOKEN IN ARGV" || ok "token not in curl's argv"
  fake "502 502 200" '{"ok":1}'
  gh_api GET /x >/dev/null; eq "502 twice then 200: retried (3 calls)" "$(cat "$t/n")" 3
  fake "404" '{"message":"Not Found"}'
  gh_api GET /x >/dev/null; eq "404 -> rc 4" "$?" 4
  fake "422" '{"message":"Validation Failed"}'
  gh_api POST /x '{}' >/dev/null; eq "422 -> rc 1" "$?" 1
  fake "403 200" '{"message":"rate"}' 'retry-after: 0\r\n'
  out=$(gh_api GET /x 2>/dev/null); eq "rate limited once: waits, retries, succeeds (2 calls)" "$(cat "$t/n")" 2
  unset -f curl; GH_QUIET=0

  c_hdr "protection JSON and digest"
  d=$(gh__protect_json)
  eq "baseline: no required checks" "$(jq -c '.required_status_checks' <<<"$d")" null
  eq "baseline: admins enforced" "$(jq -c '.enforce_admins' <<<"$d")" true
  d=$(gh__protect_json build "lint / lint")
  eq "with checks" "$(jq -c '[.required_status_checks.checks[].context]' <<<"$d")" '["build","lint / lint"]'
  cat > "$t/prot.json" <<'EOF'
{"enforce_admins":{"enabled":true},"required_pull_request_reviews":{"required_approving_review_count":0},
 "required_status_checks":{"strict":false,"contexts":["build"],"checks":[{"context":"build","app_id":15368}]},
 "allow_force_pushes":{"enabled":false}}
EOF
  eq "digest" "$(gh_protection_digest < "$t/prot.json")" '{"enforce_admins":true,"contexts":["build"],"pr_required":true,"force_push":false}'
  eq "digest of nothing set" "$(echo '{}' | gh_protection_digest)" '{"enforce_admins":false,"contexts":[],"pr_required":false,"force_push":false}'

  c_hdr "runs, check runs, PR, GHCR parsing"
  cat > "$t/runs.json" <<'EOF'
{"workflow_runs":[
 {"id":1,"name":"CI","path":".github/workflows/ci.yml","event":"push","status":"completed","conclusion":"failure","created_at":"2026-10-17T10:00:00Z"},
 {"id":2,"name":"CI","path":".github/workflows/ci.yml","event":"workflow_dispatch","status":"completed","conclusion":"success","created_at":"2026-10-17T10:05:00Z"},
 {"id":3,"name":"CI","path":".github/workflows/ci.yml","event":"pull_request","status":"in_progress","conclusion":null,"created_at":"2026-10-17T10:06:00Z"},
 {"id":4,"name":"other","path":".github/workflows/x.yml","event":"push","status":"completed","conclusion":"success","created_at":"2026-10-17T10:07:00Z"}]}
EOF
  eq "runs since 10:04: 2 runs, 1 pending, 0 bad" "$(gh_runs_summary 2026-10-17T10:04:00Z < "$t/runs.json")" "3 1 0"
  eq "runs since 09:00: counts the failure" "$(gh_runs_summary 2026-10-17T09:00:00Z < "$t/runs.json")" "4 1 1"
  eq "newest ci.yml run (no event filter)" "$(jq -c --arg ev "" '[.workflow_runs[]|select(((.path // "")|startswith(".github/workflows/ci.yml")) or .name=="CI")|select($ev==""or .event==$ev)]|sort_by(.created_at)|last|.id' < "$t/runs.json")" 3
  cat > "$t/checks.json" <<'EOF'
{"check_runs":[{"name":"build (3.12)","status":"completed","conclusion":"success"},{"name":"lint / lint","status":"completed","conclusion":"success"},{"name":"publish","status":"queued","conclusion":null}]}
EOF
  eq "check runs as TSV" "$(jq -r '.check_runs[]|[.name,.status,(.conclusion // "-")]|@tsv' < "$t/checks.json" | tr '\t' ',' | tr '\n' ';')" "build (3.12),completed,success;lint / lint,completed,success;publish,queued,-;"
  eq "PR digest" "$(echo '{"state":"open","merged":false,"head":{"sha":"abc"},"mergeable":true,"mergeable_state":"blocked"}' | gh_pr_digest)" '{"state":"open","merged":false,"head":"abc","mergeable":true,"mergeable_state":"blocked"}'
  eq "GHCR tags" "$(echo '[{"metadata":{"container":{"tags":["sha-1234567","latest"]}}},{"metadata":{"container":{"tags":[]}}}]' | jq -r '.[].metadata.container.tags[]?' | tr '\n' ' ')" "sha-1234567 latest "

  c_hdr "workflow permissions"
  cat > "$t/good.yml" <<'EOF'
name: CI
on: push
permissions:
  contents: read
jobs:
  lint:
    uses: o/r/.github/workflows/x.yml@v1.0.0
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read   # why
      packages: write
    steps:
      - run: echo permissions: not-a-key
EOF
  eq "least privilege parsed" "$(gh_wf_permissions < "$t/good.yml" | tr '\t\n' ' :')" "top contents read:job:publish contents read:job:publish packages write:"
  cat > "$t/bad1.yml" <<'EOF'
permissions:
  contents: read
  packages: write
jobs:
  a:
    runs-on: x
  publish:
    permissions: write-all
    steps: []
EOF
  eq "workflow-level grant and write-all" "$(gh_wf_permissions < "$t/bad1.yml" | tr '\t\n' ' :')" "top contents read:top packages write:job:publish * write-all:"
  printf 'permissions: write-all\njobs:\n  a:\n    permissions: {contents: read, packages: write}\n' > "$t/bad2.yml"
  eq "one-line forms" "$(gh_wf_permissions < "$t/bad2.yml" | tr '\t\n' ' :')" "top * write-all:job:a * {contents: read, packages: write}:"

  c_hdr "pull_request trigger block"
  cat > "$t/on1.yml" <<'EOF'
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
    paths:
      - "src/**"
      - 'tests/**'
  workflow_dispatch:
jobs:
  x: {}
EOF
  out=$(gh_wf_event_block pull_request < "$t/on1.yml")
  eq "block found with its paths" "$(tr '\n' '|' <<<"$out")" 'EVENT pull_request|  branches: [main]|  paths:|    - "src/**"|    - '"'"'tests/**'"'"'|'
  printf 'on: [push, pull_request]\njobs: {}\n' > "$t/on2.yml"
  eq "flow style recognised" "$(gh_wf_event_block pull_request < "$t/on2.yml")" "EVENT pull_request (flow style)"
  printf 'on:\n  push:\n  pull_request_target:\n' > "$t/on3.yml"
  eq "pull_request_target is not pull_request" "$(gh_wf_event_block pull_request < "$t/on3.yml")" ""
  printf 'on:\n  pull_request:\n    paths-ignore:\n      - "**.md"\n' > "$t/on4.yml"
  eq "paths-ignore is kept apart from paths" "$(gh_wf_event_block pull_request < "$t/on4.yml" | grep -c '^ *paths:')" 0
  covers='service|["'"'"' ]\*\*(/[^"'"'"']*)?["'"'"' ,]*$'
  echo '  - "src/**"' | grep -Eq "$covers" && no "src/** wrongly covers service/" || ok "src/** does not cover service/"
  echo '  - "service/**"' | grep -Eq "$covers" && ok "service/** covers" || no "service/** not recognised"
  echo '  - "**"' | grep -Eq "$covers" && ok "bare ** covers" || no "bare ** not recognised"
  echo '  - "**/*.py"' | grep -Eq "$covers" && ok "**/*.py covers" || no "**/*.py not recognised"

  c_hdr "reusable-workflow refs"
  printf '  lint:\n    uses: octo-cat/playground-workflows/.github/workflows/python-lint.yml@main\n  l2:\n    uses: octo-cat/playground-workflows/.github/workflows/python-lint.yml@v1.0.1 # pinned\n  l3:\n    uses: o/playground-workflows/.github/workflows/p.yml@%s\n  z:\n    uses: actions/checkout@v4\n' "$(printf 'a%.0s' $(seq 1 40))" > "$t/uses.yml"
  eq "refs of the shared repo only" "$(gh_uses_refs playground-workflows < "$t/uses.yml" | tr '\n' ' ')" "main v1.0.1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "
  eq "main is a branch" "$(gh_ref_kind main)" branch
  eq "v1.0.1 is a tag" "$(gh_ref_kind v1.0.1)" tag
  eq "v2 is a tag" "$(gh_ref_kind v2)" tag
  eq "40 hex is a sha" "$(gh_ref_kind "$(printf 'b%.0s' $(seq 1 40))")" sha
  eq "release/1 is a branch" "$(gh_ref_kind release/1)" branch

  rm -rf "$t"
  echo
  if (( fails )); then c_bad "$fails self-test check(s) failed"; return 1; fi
  c_ok "github.sh self-test passed"
}
