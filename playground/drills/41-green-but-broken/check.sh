#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
BR=drill41-canary
JOB="/job/demo-api/job/$BR"
repo=$(repo_url payments/demo-api)
scratch="$STATE/scratch/check41"
cleanup() { git push -q "$repo" --delete "$BR" >/dev/null 2>&1 || true; rm -rf "$scratch"; }
trap cleanup EXIT

# 1. main is green AFTER the incident started, and what runs is main's HEAD.
assert_main_green_since "$DRILL_STARTED" || exit 1

# 2. Green must mean something: that build has to REPORT tests. A green build
#    with no test report is exactly what the incident was.
rep=$(jenkins_get "/job/demo-api/job/main/lastBuild/testReport/api/json?tree=passCount,failCount,skipCount" 2>/dev/null || true)
[[ -n $rep ]] || rep='{}'
total=$(jq -r '(.passCount // 0) + (.failCount // 0) + (.skipCount // 0)' <<<"$rep" 2>/dev/null); total=${total:-0}
skipped=$(jq -r '.skipCount // 0' <<<"$rep" 2>/dev/null); skipped=${skipped:-0}
if (( total == 0 )); then
  c_bad "main is green but reported NO tests -- nothing proves they ran (is there a 'Test Result' on the build?)"; exit 1
fi
c_ok "main's build reported $total tests"

# 3. The bug itself, in what is actually running (not in the repo).
body=$(K -n demo-ci exec deploy/demo-api -- python -c \
  "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/', timeout=5).read().decode())" 2>/dev/null || true)
[[ -n $body ]] || body='{}'
name=$(jq -r '.app // "null"' <<<"$body" 2>/dev/null)
if [[ $name != demo-api ]]; then
  c_bad "the running service still answers app=\"$name\" on / -- the bug is still shipped"; exit 1
fi
c_ok "the running service reports app=\"demo-api\""

# 4. The real proof: can this pipeline fail again? Push a branch whose only
#    change is a test that must fail, and watch what Jenkins makes of it.
c_dim "  proving a failing test turns the build red: throwaway branch $BR (about 2 minutes)"
before=$(jenkins_get "$JOB/api/json?tree=lastBuild%5Bnumber%5D" 2>/dev/null | jq -r '.lastBuild.number // 0' 2>/dev/null)
before=${before:-0}
rm -rf "$scratch"
git clone -q "$repo" "$scratch" 2>/dev/null || { c_bad "could not clone payments/demo-api for the canary"; exit 1; }
git -C "$scratch" checkout -q -b "$BR"
cat > "$scratch/test_zz_canary.py" <<'PY'
def test_canary_must_fail_the_build():
    assert False, "deliberate failure from the drill 41 check"
PY
git -C "$scratch" add -A
git -C "$scratch" -c user.name="drill check" -c user.email=check@playground.local \
  commit -q -m "drill 41 canary: a test that must fail the build"
git -C "$scratch" push -q origin "$BR" 2>/dev/null || { c_bad "could not push the canary branch"; exit 1; }
jenkins_scan
t0=$(date +%s); res=""
while (( $(date +%s) - t0 < 420 )); do
  b=$(jenkins_get "$JOB/lastBuild/api/json?tree=number,result,building" 2>/dev/null || echo '{}')
  n=$(jq -r '.number // 0' <<<"$b" 2>/dev/null); n=${n:-0}
  if (( n > before )) && [[ $(jq -r '.building' <<<"$b") == false ]]; then res=$(jq -r '.result' <<<"$b"); break; fi
  sleep 8
done
case $res in
  FAILURE) c_ok "a failing test makes the build FAILURE again" ;;
  UNSTABLE) c_bad "a failing test only makes the build UNSTABLE (yellow) -- the failure is still being swallowed and a yellow main still deploys"; exit 1 ;;
  SUCCESS) c_bad "a branch with a deliberately failing test built GREEN -- the test step still cannot fail"; exit 1 ;;
  "") c_warn "the canary build did not finish within 7 minutes -- check again once Jenkins is idle"; exit 1 ;;
  *) c_bad "canary build ended $res instead of FAILURE"; exit 1 ;;
esac

# 5. Penalties: fixes that go green but would hurt at work.
now=$(curl -fsS "$GITEA_URL/payments/demo-api/raw/branch/main/test_app.py" 2>/dev/null || true)
base=$(curl -fsS "$GITEA_URL/payments/demo-api/raw/tag/baseline/test_app.py" 2>/dev/null || true)
n_now=$(grep -c '^def test_' <<<"$now"); n_base=$(grep -c '^def test_' <<<"$base")
if (( n_now < n_base )) || grep -Eqi 'skip|xfail' <<<"$now" || ! grep -q 'body\["app"\] == "demo-api"' <<<"$now" || (( skipped > 0 )); then
  echo "PENALTY 40 You made the pipeline green by changing the test (deleted, skipped or loosened it). The test was right and the app was wrong; a gate you edit until it passes is not a gate."
fi
jf=$(curl -fsS "$GITEA_URL/payments/demo-api/raw/branch/main/Jenkinsfile" 2>/dev/null || true)
if grep -Eq 'allowEmptyResults|skipMarkingBuildUnstable|catchError|\|\| *true|; *true' <<<"$jf"; then
  echo "PENALTY 10 The Jenkinsfile still carries a construct that can swallow a failure (|| true, catchError, allowEmptyResults...). It works today because nothing fails."
fi
