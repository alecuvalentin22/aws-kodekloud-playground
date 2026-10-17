#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/github.sh"; gh_load_env
r=$GH_APP1; base="/repos/$GITHUB_OWNER/$r"
n=$(gh_state_get drill32.pr)
[[ -n $n ]] || { c_bad "no drill state (was it reset?). play reveal, play reset, start again."; exit 1; }

# The rule, as it stands now.
pen=()   # penalties, printed once the drill is solved
if prot=$(GH_QUIET=1 gh_api GET "$base/branches/main/protection"); then
  dig=$(gh_protection_digest <<<"$prot")
  admins=$(jq -r .enforce_admins <<<"$dig"); prreq=$(jq -r .pr_required <<<"$dig")
  ctxs=$(jq -r '.contexts[]' <<<"$dig")
  [[ $admins == true ]] || pen+=("PENALTY 40 'Do not allow bypassing the above settings' is off: admins can merge past every rule. That is the override, not the fix.")
  [[ $prreq == true ]] || pen+=("PENALTY 25 The pull-request requirement is gone from main: anyone can push to it.")
  [[ -n $ctxs ]] || pen+=("PENALTY 40 main requires no status checks any more. That makes the PR mergeable by deleting the guard.")
else
  ctxs=""
  pen+=("PENALTY 50 The branch protection on main was removed. Priya can merge; so can anyone, with nothing checked.")
fi

# Priya's PR.
pr=$(gh_pr_mergeable "$r" "$n") || exit 1
state=$(jq -r .state <<<"$pr"); head=$(jq -r .head <<<"$pr"); ms=$(jq -r .mergeable_state <<<"$pr"); merged=$(jq -r .merged <<<"$pr")
if [[ $state == closed && $merged != true ]]; then c_bad "Priya's PR #$n was closed without merging."; exit 1; fi

checks=$(gh_check_runs "$r" "$head")
if [[ $merged != true ]] && grep -Eq $'\t(queued|in_progress|waiting|pending)\t' <<<"$checks"; then
  c_warn "checks on PR #$n are still running. Check again when they finish."; exit 1
fi
if [[ -n $ctxs ]]; then
  bad=0
  while IFS= read -r c; do
    if awk -F'\t' -v c="$c" '$1 == c && $3 == "success" { f = 1 } END { exit !f }' <<<"$checks"; then
      c_ok "required check '$c' is reported by the PR and green"
    else
      c_bad "required check '$c' is not reported (green) on PR #$n. The PR reports: $(cut -f1 <<<"$checks" | tr '\n' ',' | sed 's/,$//')"; bad=1
    fi
  done <<<"$ctxs"
  (( bad )) && exit 1
fi
if [[ $merged == true ]]; then
  c_ok "PR #$n is merged"
else
  case $ms in
    clean|unstable|has_hooks) c_ok "PR #$n is mergeable ($ms)" ;;
    blocked) c_bad "PR #$n is still blocked (a required check or review is missing). Look at the merge box."; exit 1 ;;
    behind)  c_bad "PR #$n is behind main; update the branch."; exit 1 ;;
    dirty)   c_bad "PR #$n has conflicts with main."; exit 1 ;;
    *)       c_warn "mergeable_state is '$ms'; check again in a few seconds."; exit 1 ;;
  esac
fi
for p in "${pen[@]+"${pen[@]}"}"; do echo "$p"; done
exit 0
