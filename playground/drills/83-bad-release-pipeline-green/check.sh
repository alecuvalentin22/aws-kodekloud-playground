#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
[[ -f $SF ]] || { c_bad "no record from break.sh (drill not started properly?)"; exit 1; }
# shellcheck disable=SC1090
source "$SF"        # BREAK_REV GOOD_REV BASE_VER V1_UID TAG
out="$STATE/scratch/check$N.console"
trap 'rm -f "$out"' EXIT

fail_flag() { K -n "$NS" get cm "$FULL" -o jsonpath='{.data.FAIL_HEALTH}' 2>/dev/null; }
# serving -- the release answers THROUGH the Service, on a config that is not the bad one
serving() {
  [[ $(fail_flag) != true ]] || return 1
  K -n "$NS" rollout status "deploy/$FULL" --timeout=5s >/dev/null 2>&1 || return 1
  [[ $(svc_get /healthz | jq -r .status 2>/dev/null) == ok ]]
}

# 1. Staging serves again, on a good config.
st=$(rel_field .info.status); rev=$(rel_field .version)
[[ -n $st ]] || { c_bad "release $REL is gone from $NS (helm -n $NS list)"; exit 1; }
if [[ $st != deployed ]]; then c_bad "release $REL is '$st' at revision $rev (helm -n $NS history $REL)"; exit 1; fi
if [[ $(fail_flag) == true ]]; then
  c_bad "the ConfigMap still says FAIL_HEALTH=true (release revision $rev): staging is not back. Which revision was the last good one? (helm -n $NS history $REL)"; exit 1
fi
ok=0
for _ in $(seq 1 20); do serving && { ok=1; break; }; sleep 3; done
(( ok )) || { c_bad "staging is not serving: the pods are not Ready or GET /healthz through the Service fails (kubectl -n $NS get pods,endpointslices)"; exit 1; }
replicas=$(K -n "$NS" get deploy "$FULL" -o jsonpath='{.spec.replicas}')
ready=$(K -n "$NS" get endpointslices -l "kubernetes.io/service-name=$FULL" -o json | jq '[.items[].endpoints[]? | select((.conditions.ready // true) == true)] | length')
(( ${ready:-0} >= ${replicas:-1} )) || { c_bad "Service $FULL has ${ready:-0} ready endpoint(s) for $replicas replicas"; exit 1; }
c_ok "staging serves again: $ready ready endpoints, /healthz ok through the Service (release revision $rev)"

# 2. How: history kept, or thrown away?
uid=$(K -n "$NS" get secret "sh.helm.release.v1.$REL.v1" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
if [[ $uid != "$V1_UID" ]]; then
  c_warn "release $REL was uninstalled and installed again: its history (revisions 1-$BREAK_REV) is gone"
  echo "PENALTY 25 helm uninstall + install: the revision history is lost, so there is no known-good revision to return to and no record of what changed. helm rollback <revision> exists for exactly this."
else
  c_ok "release history intact (revision 1 is still the original; now at $rev)"
fi

# 3. The pipeline: the helm upgrade command must wait, undo itself and have a deadline. Comments do not count.
scratch="$STATE/scratch/check$N.jf"; trap 'rm -f "$out" "$scratch"' EXIT
curl -fsS "$GITEA_URL/$REPO/raw/branch/main/Jenkinsfile.helm" -o "$scratch" 2>/dev/null || { c_bad "cannot read Jenkinsfile.helm from $REPO (main)"; exit 1; }
code=$(grep -vE '^[[:space:]]*(//|#)' "$scratch")
blk=$(awk '/^[[:space:]]*helm[[:space:]]+upgrade/ {on=1} on {print} on && !/\\[[:space:]]*$/ {on=0}' <<<"$code")
if [[ -z $blk ]]; then c_bad "no 'helm upgrade' command found in Jenkinsfile.helm on main"; exit 1; fi
miss=""
grep -q -- '--wait' <<<"$blk" || miss="$miss --wait"
grep -Eq -- '--atomic|--rollback-on-failure' <<<"$blk" || miss="$miss --atomic(Helm 3)/--rollback-on-failure(Helm 4)"
grep -q -- '--timeout' <<<"$blk" || miss="$miss --timeout"
if [[ -n $miss ]]; then
  c_bad "the helm upgrade in Jenkinsfile.helm on main is missing:$miss -- (pushed? committed to main?) without them 'green' only means the API accepted the YAML"; exit 1
fi
c_ok "Jenkinsfile.helm waits for the rollout, rolls back on failure and has a timeout"
grep -Eq 'helm .*[[:space:]]test([[:space:]]|$)' <<<"$code" && has_test=1 || has_test=0

# 4. The proof, on the real pipeline: ship a deliberately broken release. It must FAIL and leave the running release serving.
c_dim "  proving a broken deploy fails and changes nothing: running $JOB with config.FAIL_HEALTH=true, --timeout 60s (about 3 minutes)"
for _ in $(seq 1 60); do   # let a build of yours finish first
  b=$(jenkins_get "/job/$JOB/api/json?tree=lastBuild%5Bbuilding%5D,inQueue" 2>/dev/null || echo '{}')
  [[ $(jq -r '(.lastBuild.building // false) or (.inQueue // false)' <<<"$b") == false ]] && break; sleep 5
done
pre_rev=$(rel_field .version)
pre_values=$(HELM -n "$NS" get values "$REL" -o json 2>/dev/null | jq -S -c .)
restore() { if [[ $(fail_flag) == true ]]; then HELM -n "$NS" rollback "$REL" "$pre_rev" --wait --timeout 150s >/dev/null 2>&1 || true; fi; }
job_run "$out" 540 "EXTRA_SET=config.FAIL_HEALTH=true" "TIMEOUT=60s" "IMAGE_TAG=$TAG" || { c_bad "could not start a build of $JOB"; exit 1; }
case $JOB_RESULT in
  FAILURE) ;;
  TIMEOUT) c_warn "the proof build #$JOB_NUM did not finish within 9 minutes -- check again once Jenkins is idle"; exit 1 ;;
  *) restore
     c_bad "a deliberately broken release (FAIL_HEALTH=true) built $JOB_RESULT in #$JOB_NUM: the pipeline would ship it again. (The check put the release back for you.)"; exit 1 ;;
esac
c_ok "the broken release failed the pipeline (#$JOB_NUM FAILURE)"
bad_rev=$(HELM -n "$NS" history "$REL" -o json 2>/dev/null | jq -r --argjson p "$pre_rev" '[.[] | select(.revision > $p and .status == "failed")] | last | .revision // empty')
if [[ -z $bad_rev ]]; then
  restore
  c_bad "build #$JOB_NUM failed, but Helm never recorded a failed revision: it died before the deploy, so it proves nothing about rollback. Read: $JENKINS_URL/job/$JOB/$JOB_NUM/console"
  tail -8 "$out" | sed 's/^/      /'; exit 1
fi
if [[ $(HELM -n "$NS" get values "$REL" --revision "$bad_rev" -o json 2>/dev/null | jq -r '.config.FAIL_HEALTH | tostring') != true ]]; then
  restore; c_bad "revision $bad_rev (failed) was not the broken release; the build failed for another reason: $JENKINS_URL/job/$JOB/$JOB_NUM/console"; exit 1
fi
c_ok "Helm recorded the broken release as revision $bad_rev (failed) and went back"
ok=0
for _ in $(seq 1 50); do
  [[ $(rel_field .info.status) == deployed ]] && serving && { ok=1; break; }; sleep 3
done
if (( ! ok )); then
  restore
  c_bad "after the failed build the release is not serving: the bad release is still live ($(rel_field .info.status), FAIL_HEALTH=$(fail_flag)). The pipeline failed but did not undo it."; exit 1
fi
post_values=$(HELM -n "$NS" get values "$REL" -o json 2>/dev/null | jq -S -c .)
if [[ $post_values != "$pre_values" ]]; then
  c_bad "after the failed build the running release does not have the values it had before: $post_values (was $pre_values)"; exit 1
fi
c_ok "the previous release is still serving: same values as before, /healthz ok through the Service"

# 5. Penalties.
if (( ! has_test )); then
  echo "PENALTY 15 The Test stage (helm test) is still gone from Jenkinsfile.helm. --wait proves the pods are Ready; only helm test proves the Service routes to them (drill 81). It was part of the pipeline for a reason."
fi
exit 0
