#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/github.sh"; gh_load_env
r=$GH_APP1 pen=()
bad=$(gh_state_get drill34.bad-sha)
[[ -n $bad ]] || { c_bad "no drill state (was it reset?). play reveal, play reset, start again."; exit 1; }

head=$(gh_head "$r" main)
if [[ $head == "$bad" ]]; then c_bad "main is still the commit that broke publish (${head:0:7}). The fix has to reach main, through a pull request."; exit 1; fi

run=$(gh_latest_run "$r" "$head" push)
if [[ -z $run || $run == null ]]; then c_warn "no push run yet for main ${head:0:7}. Check again in a minute."; exit 1; fi
if [[ $(jq -r .status <<<"$run") != completed ]]; then c_warn "the run for main ${head:0:7} is still $(jq -r .status <<<"$run"). Check again when it finishes."; exit 1; fi
jobs=$(gh_run_jobs "$r" "$(jq -r .id <<<"$run")")
pub=$(awk -F'\t' '$1 == "publish" { print $2 }' <<<"$jobs")
if [[ $pub != success ]]; then
  c_bad "the publish job on main ${head:0:7} is '${pub:-missing}': $(jq -r .html_url <<<"$run")"; exit 1
fi
c_ok "publish job succeeded on main ${head:0:7}"

tag="sha-${head:0:7}"
if tags=$(GH_QUIET=1 gh_ghcr_tags "$r"); then
  if grep -qx "$tag" <<<"$tags"; then c_ok "ghcr.io/.../$r:$tag exists"
  else c_bad "the job is green but the image tag $tag is not in GHCR (package $r)"; exit 1; fi
else
  c_warn "could not list the package (token without read:packages?): trusting the green publish job"
fi

# Penalties: how did you grant it?
ci=$(gh_file "$r" .github/workflows/ci.yml main)
perms=$(gh_wf_permissions <<<"$ci")
if awk -F'\t' '$1 == "top" && ($3 == "write-all" || ($2 == "packages" && $3 == "write") || $3 ~ /packages: *write/) { f = 1 } END { exit !f }' <<<"$perms"; then
  pen+=("PENALTY 25 packages: write (or write-all) at WORKFLOW level: the lint call, the tests and every job added later can publish packages. One job pushes; one job gets the permission.")
elif grep -q 'write-all' <<<"$perms"; then
  pen+=("PENALTY 25 permissions: write-all on a job: every scope, read and write, to fix one 403.")
fi
if awk -F'\t' '$1 ~ /^job:/ && $1 != "job:publish" && ($3 == "write-all" || ($2 == "packages" && $3 == "write") || $3 ~ /packages: *write/) { f = 1 } END { exit !f }' <<<"$perms"; then
  pen+=("PENALTY 15 packages: write was also given to a job that does not publish.")
fi
dwp=$(gh_api GET "/repos/$GITHUB_OWNER/$r/actions/permissions/workflow" | jq -r .default_workflow_permissions)
[[ $dwp != write ]] || pen+=("PENALTY 20 The repository's default workflow permissions are now read AND write: every workflow in this repo, now and later, gets a write token unless it opts down.")
[[ ${#pen[@]} -gt 0 ]] || c_ok "least privilege: write on the publish job only, default token read-only"
for p in "${pen[@]+"${pen[@]}"}"; do echo "$p"; done
exit 0
