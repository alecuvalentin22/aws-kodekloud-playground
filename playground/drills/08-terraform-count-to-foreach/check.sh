#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"
d="$WORK/infra"; cd "$d" || { c_bad "no $d"; exit 1; }
grep -q '"growth"' terraform.tfvars && { c_bad "growth is still in terraform.tfvars"; exit 1; }
state=$(terraform state pull 2>/dev/null) || { c_bad "cannot read state"; exit 1; }
now=$(jq -r '.resources[] | select(.name=="artifact_bucket") | .instances[] | "\(.attributes.input.value.team // .attributes.input.team) \(.attributes.id)"' <<<"$state")
fail=0
while read -r team id; do
  cur=$(awk -v t="$team" '$1==t{print $2}' <<<"$now")
  if [[ $team == growth ]]; then
    [[ -z $cur ]] && c_ok "growth's bucket is gone" || { c_bad "growth's bucket still exists (did you apply?)"; fail=1; }
  elif [[ -z $cur ]]; then c_bad "$team's bucket was DESTROYED"; fail=1
  elif [[ $cur != "$id" ]]; then c_bad "$team's bucket was REPLACED (new id) -- in AWS its contents are gone"; fail=1
  else c_ok "$team's bucket is the same bucket it always was"; fi
done < "$STATE/drill08.ids"
(( fail )) && exit 1
terraform plan -input=false -detailed-exitcode >/dev/null 2>&1; rc=$?
(( rc == 0 )) || { c_bad "plan is not clean (exit $rc): state and code disagree"; exit 1; }
c_ok "plan is clean: no changes"
grep -q 'for_each' main.tf && c_ok "keyed by name (for_each), so this cannot happen again" \
  || echo "PENALTY 10 It worked this time, but buckets are still keyed by list position."
