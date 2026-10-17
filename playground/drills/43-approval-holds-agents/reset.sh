#!/usr/bin/env bash
# Put back everything break.sh changed: the Kubernetes cloud's cap, the
# fulfilment team's job, repo and clone, and any pod a parked build still holds.
# Safe to run when drill 43 was never played (play reset runs every drill's reset).
source "$(dirname "$0")/../../lib/common.sh"; load_creds
ORG=fulfilment REPO=order-router JOB=order-router
STATE_FILE="$STATE/drill43.state"

# 1. the cap. Only if break.sh lowered it (the state file says what it was).
if [[ -f $STATE_FILE ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  jenkins_groovy "
import jenkins.model.Jenkins
def k = Jenkins.get().clouds.getByName('kubernetes')
k.setContainerCapStr('${CAP_ORIG:-10}')
Jenkins.get().save()
println 'cloud cap back to ' + k.containerCapStr" >/dev/null 2>&1
fi

# 2. the job: stop its builds first (deleting a job under a running build is messy).
if jenkins_get "/job/$JOB/api/json" >/dev/null 2>&1; then
  jenkins_groovy "
import jenkins.model.Jenkins
def p = Jenkins.get().getItem('$JOB')
p.allJobs.each { j -> j.builds.each { b -> if (b.isBuilding()) { b.doStop() } } }
sleep(3000)
p.delete()
println 'deleted'" >/dev/null 2>&1
fi

# 3. any agent pod of that job that outlived its build.
for pod in $(K -n jenkins get pods -o json 2>/dev/null \
    | jq -r '.items[] | select((.metadata.annotations.runUrl // "") | startswith("job/'"$JOB"'/")) | .metadata.name'); do
  K -n jenkins delete pod "$pod" --wait=false >/dev/null 2>&1
done

# 4. Gitea: the repo, then the org (an org with repos cannot be deleted).
gitea_api DELETE "/repos/$ORG/$REPO" >/dev/null 2>&1
gitea_api DELETE "/orgs/$ORG" >/dev/null 2>&1

# 5. the candidate's clone, only if it really is that repo.
if [[ -d $WORK/$REPO/.git ]] && git -C "$WORK/$REPO" remote get-url origin 2>/dev/null | grep -q "$ORG/$REPO"; then
  rm -rf "${WORK:?}/$REPO"
fi
rm -f "$STATE_FILE"
exit 0
