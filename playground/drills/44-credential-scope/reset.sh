#!/usr/bin/env bash
# Remove everything break.sh created: the payments and risk Jenkins folders
# (their jobs and folder-scoped credentials go with them), the global
# credential, the two Gitea repos, the risk org and the hand-off file.
# Safe to run when drill 44 was never played.
source "$(dirname "$0")/../../lib/common.sh"; load_creds

jenkins_groovy "
import jenkins.model.Jenkins
import com.cloudbees.plugins.credentials.SystemCredentialsProvider
import com.cloudbees.plugins.credentials.domains.Domain
def j = Jenkins.get()
['payments', 'risk'].each { n ->
  def f = j.getItem(n)
  if (f != null) {
    f.allJobs.each { p -> p.builds.each { b -> if (b.isBuilding()) { b.doStop() } } }
    sleep(2000)
    f.delete()
  }
}
def store = SystemCredentialsProvider.getInstance().getStore()
store.getCredentials(Domain.global()).findAll { it.id == 'artifactory-token' }.each { store.removeCredentials(Domain.global(), it) }
println 'cleaned'" >/dev/null 2>&1

for pod in $(K -n jenkins get pods -o json 2>/dev/null \
    | jq -r '.items[] | select((.metadata.annotations.runUrl // "") | (startswith("job/payments/") or startswith("job/risk/"))) | .metadata.name'); do
  K -n jenkins delete pod "$pod" --wait=false >/dev/null 2>&1
done

gitea_api DELETE /repos/payments/ledger-export >/dev/null 2>&1
gitea_api DELETE /repos/risk/fraud-scorer >/dev/null 2>&1
gitea_api DELETE /orgs/risk >/dev/null 2>&1

# the candidate's clone of risk's repo, only if it really is that repo
if [[ -d $WORK/fraud-scorer/.git ]] && git -C "$WORK/fraud-scorer" remote get-url origin 2>/dev/null | grep -q 'risk/fraud-scorer'; then
  rm -rf "${WORK:?}/fraud-scorer"
fi
rm -f "$WORK/handoff/risk-artifactory-token.txt"
rmdir "$WORK/handoff" 2>/dev/null
rm -f "$STATE/drill44.state"
exit 0
