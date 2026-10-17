#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/github.sh"; gh_load_env
r=$GH_APP1; fail=0
n=$(gh_state_get drill31.pr)
[[ -n $n ]] || { c_bad "no drill state (was it reset?). play reveal, play reset, start again."; exit 1; }

# 1. The trigger on main: read it as text (heuristic, see lib/github.sh).
ci=$(gh_file "$r" .github/workflows/ci.yml main) || { c_bad "cannot read ci.yml on main"; exit 1; }
blk=$(gh_wf_event_block pull_request <<<"$ci")
nofilter=0
if [[ -z $blk ]]; then
  c_bad "ci.yml on main does not run on pull_request at all"; fail=1
else
  paths=$(awk '/^ *paths:/ { p = 1; print; next } p && /^ *- / { print; next } { p = 0 }' <<<"$blk")
  brs=$(awk '/^ *branches:/ { p = 1; print; next } p && /^ *- / { print; next } { p = 0 }' <<<"$blk")
  if [[ -n $paths ]] && ! grep -Eq "service|[\"' ]\*\*(/[^\"']*)?[\"' ,]*\$" <<<"$paths"; then
    c_bad "pull_request only runs when a PR touches: $(tr -s ' \n' ' ' <<<"$paths" | sed 's/paths://')-- this repo's code is in service/"; fail=1
  elif [[ -n $brs ]] && ! grep -Eq 'main|\*' <<<"$brs"; then
    c_bad "pull_request only runs for PRs into: $(tr -s ' \n' ' ' <<<"$brs") -- not main"; fail=1
  else
    c_ok "the pull_request trigger now matches changes to service/"
  fi
  grep -Eq '^ *(paths|paths-ignore):' <<<"$blk" || nofilter=1
fi

# 2. Sam's pull request has real checks.
pr=$(gh_api GET "/repos/$GITHUB_OWNER/$r/pulls/$n") || exit 1
state=$(jq -r .state <<<"$pr"); merged=$(jq -r '.merged // false' <<<"$pr"); head=$(jq -r .head.sha <<<"$pr")
prrun=$(gh_latest_run "$r" "$head" pull_request)
unchecked=0
if [[ $state == closed && $merged != true ]]; then
  c_bad "Sam's PR #$n was closed without merging. Reopen it: it is what the ticket is about."; fail=1
elif [[ $merged == true ]]; then
  c_ok "PR #$n is merged"
  [[ -z $prrun || $prrun == null ]] && unchecked=1
  mrun=$(gh_latest_run "$r" "$(gh_head "$r" main)" push)
  if [[ -z $mrun || $mrun == null || $(jq -r .status <<<"$mrun") != completed ]]; then c_warn "main's own CI run is not finished yet -- check again in a minute"; fail=1
  elif [[ $(jq -r .conclusion <<<"$mrun") != success ]]; then c_bad "CI on main is $(jq -r .conclusion <<<"$mrun")"; fail=1; fi
elif [[ -z $prrun || $prrun == null ]]; then
  c_bad "PR #$n (head ${head:0:7}) still has no pull_request run. After the trigger is fixed on main, the PR needs a new event: update the branch, or close and reopen it."; fail=1
elif [[ $(jq -r .status <<<"$prrun") != completed ]]; then
  c_warn "PR #$n has a run, still $(jq -r .status <<<"$prrun"). Check again when it finishes."; fail=1
elif [[ $(jq -r .conclusion <<<"$prrun") != success ]]; then
  c_bad "PR #$n has a run but it is $(jq -r .conclusion <<<"$prrun"): $(jq -r .html_url <<<"$prrun")"; fail=1
else
  c_ok "PR #$n head ${head:0:7} has a successful pull_request run:"
  gh_check_runs "$r" "$head" | awk -F'\t' '{printf "      %-22s %s\n", $1, $3}'
fi
(( fail )) && exit 1

# Penalties (only printed once the drill is solved).
for f in $(gh_api GET "/repos/$GITHUB_OWNER/$r/contents/.github/workflows?ref=main" | jq -r '.[].name'); do
  if gh_file "$r" ".github/workflows/$f" main | sed -E 's/[[:space:]]*#.*$//' | grep -q 'pull_request_target'; then
    echo "PENALTY 30 $f uses pull_request_target: it runs with the base repo's secrets and a write token, and the usual next step is checking out the PR's code. That is how a stranger's PR steals your secrets."
  fi
done
(( nofilter )) && echo "PENALTY 10 Every filter is gone: docs-only PRs run the whole pipeline again. The repo had paths-ignore for a reason."
(( unchecked )) && echo "PENALTY 20 Sam's PR was merged without a single check having run on it. The point was to make the checks run first."
exit 0
