#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/github.sh"; gh_load_env
fail=0 pen=()
bad=$(gh_state_get drill33.bad-sha)
[[ -n $bad ]] || { c_bad "no drill state (was it reset?). play reveal, play reset, start again."; exit 1; }
wfbase="/repos/$GITHUB_OWNER/$GH_WF"

# 1. Is the shared repo's main usable by an UNCHANGED caller again?
lint=$(gh_file "$GH_WF" .github/workflows/python-lint.yml main | sed -E 's/[[:space:]]*#.*$//')
if grep -Eq 'required: *true' <<<"$lint"; then
  c_bad "playground-workflows main still has a REQUIRED input: an unchanged caller still fails to start"; fail=1
else
  c_ok "the shared workflow on main accepts existing callers again"
fi

# 2. Callers: pinned to a tag or a SHA, never a branch, and green.
for r in $GH_APP1 $GH_APP2; do
  ci=$(gh_file "$r" .github/workflows/ci.yml main)
  refs=$(gh_uses_refs "$GH_WF" <<<"$ci")
  if [[ -z $refs ]]; then c_bad "$r: ci.yml no longer calls the shared workflow"; fail=1; continue; fi
  for ref in $refs; do
    case $(gh_ref_kind "$ref") in
      branch) c_bad "$r follows the BRANCH '$ref': the next commit there reaches it instantly"; fail=1 ;;
      tag)    if gh_tag_sha "$GITHUB_OWNER" "$GH_WF" "$ref" >/dev/null 2>&1; then c_ok "$r pins the release $ref"
              else c_bad "$r pins '$ref', which is not a tag in $GH_WF"; fail=1; fi ;;
      sha)    if GH_QUIET=1 gh_api GET "$wfbase/commits/$ref" >/dev/null; then c_ok "$r pins the commit ${ref:0:10}"
              else c_bad "$r pins ${ref:0:10}, which is not a commit in $GH_WF"; fail=1; fi ;;
    esac
  done
  sha=$(gh_head "$r" main); run=$(gh_latest_run "$r" "$sha")
  if [[ -z $run || $run == null ]]; then c_warn "$r: no CI run yet for main ${sha:0:7}"; fail=1
  elif [[ $(jq -r .status <<<"$run") != completed ]]; then c_warn "$r: CI is still $(jq -r .status <<<"$run") on main ${sha:0:7}"; fail=1
  elif [[ $(jq -r .conclusion <<<"$run") != success ]]; then c_bad "$r: CI on main is $(jq -r .conclusion <<<"$run"): $(jq -r .html_url <<<"$run")"; fail=1
  else c_ok "$r: CI green on main (${sha:0:7})"; fi
done
(( fail )) && exit 1

# 3. Penalties, and a nudge about the release.
st=$(GH_QUIET=1 gh_api GET "$wfbase/compare/$bad...main" 2>/dev/null | jq -r .status)
case $st in
  ahead|identical) c_ok "shared main fixed forward (history intact)" ;;
  *) pen+=("PENALTY 15 You rewrote main's history on a shared repo. Everyone with a clone now has a diverged main; git revert says the same thing without that.") ;;
esac
cur=$(gh_tag_sha "$GITHUB_OWNER" "$GH_WF" v1.0.0 2>/dev/null)
[[ $cur == "$(gh_state_get v1.0.0-sha)" ]] || pen+=("PENALTY 15 The tag v1.0.0 was moved or deleted. A released tag is a promise: whoever pinned it now runs different code with no commit of their own. Cut v1.0.1.")
tags=$(gh_api GET "$wfbase/tags?per_page=100" | jq -r '.[].name' | grep -Evx 'baseline|v1\.0\.0')
[[ -n $tags ]] && c_ok "release(s) cut: $(tr '\n' ' ' <<<"$tags")" || c_warn "no new release tag: you pinned to v1.0.0 (fine) but the fixed main has no version. Say how you would release it."
for p in "${pen[@]+"${pen[@]}"}"; do echo "$p"; done
exit 0
