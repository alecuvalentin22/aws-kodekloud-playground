#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"
fail=0; bad() { c_bad "$*"; fail=1; }
snap="$STATE/drill09.tags"
[[ -f $snap ]] || { c_bad "no tag snapshot from break.sh (drill not started properly?)"; exit 1; }

# 1. demo-api: main is green, after the incident started, and is what runs.
assert_main_green_since "$DRILL_STARTED" || fail=1

# 2. The library, from a fresh clone.
d="$STATE/scratch/check09"; rm -rf "$d"; git clone -q "$(repo_url platform/platform-lib)" "$d" || { c_bad "cannot clone platform-lib"; exit 1; }
trap 'rm -rf "$d"' EXIT
tagsha() { git -C "$d" rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null; }

# 2a. Nothing that existed was moved.
moved=0
while read -r name sha; do
  [[ $(tagsha "$name") == "$sha" ]] || moved=1
done < "$snap"
(( moved )) && echo "PENALTY 25 An existing tag was moved or deleted (v1.0.0 must never change: search-indexer is pinned to it, and 'immutable release' is the whole point of a tag)"

# 2b. A NEW version exists.
newtags=$(git -C "$d" tag | grep -vxFf <(awk '{print $1}' "$snap") | sort -V)
jf=$(curl -fsS "$GITEA_URL/payments/demo-api/raw/branch/main/Jenkinsfile")
pin=$(grep -oE "platform-lib@[^'\"]*" <<<"$jf" | head -1 | cut -d@ -f2)
if [[ -z $newtags ]]; then
  bad "platform-lib has no new version tag (a release is a tag: v1.0.0 is still the latest)"
  tag=""
else
  if [[ -n $pin ]] && grep -qxF -e "$pin" <<<"$newtags"; then tag=$pin; else tag=$(tail -1 <<<"$newtags"); fi
  c_ok "new platform-lib tag(s): $(tr '\n' ' ' <<<"$newtags")"
fi

# 2c. The step is in that release.
if [[ -n $tag ]]; then
  src=$(git -C "$d" show "$tag:vars/pytestCommand.groovy" 2>/dev/null)
  if [[ -z $src ]]; then bad "$tag has no vars/pytestCommand.groovy (tagged before the step was committed?)"
  elif ! grep -qE '(def|String|Object) +call *\(' <<<"$src"; then bad "vars/pytestCommand.groovy has no call(...) method"
  else
    c_ok "$tag contains vars/pytestCommand.groovy with a call()"
    grep -qE '^[[:space:]]*(/\*\*|//)' <<<"$src" || echo "PENALTY 3 The step has no doc comment. The next team reads it before using it: what it returns, how to call it."
    if ! git -C "$d" diff --quiet baseline "$tag" -- vars/standardPipeline.groovy vars/buildImage.groovy vars/deployToEks.groovy src resources; then
      echo "PENALTY 12 The release also changed existing steps. Other teams on this tag now run different code than the ticket promised: a minor release should be purely additive."
    fi
    if git -C "$d" merge-base --is-ancestor "$tag" origin/main; then
      git -C "$d" diff --quiet "$tag" origin/main -- vars src resources \
        || echo "PENALTY 8 main has library changes after $tag that no tag contains. Unpinned consumers get them instantly; release them or revert them."
    else
      echo "PENALTY 10 $tag is not on main. The next release cut from main will silently drop the step."
    fi
    case $tag in
      v[0-9]*.[0-9]*.[0-9]*) [[ $tag == v1.* ]] || echo "PENALTY 3 A purely additive change is a MINOR bump (v1.1.0). A major version tells every team it breaks them." ;;
      *) echo "PENALTY 5 $tag is not a semantic version (vMAJOR.MINOR.PATCH). Consumers cannot tell a safe upgrade from a breaking one." ;;
    esac
  fi
fi

# 3. demo-api uses it, pinned, and the copy is gone.
if grep -qE 'python -m pytest|pip install|junitxml|pytestFlags' <<<"$jf"; then
  bad "demo-api's Jenkinsfile still contains the copy-pasted test block"
else c_ok "the copy-pasted block is gone from demo-api"; fi
grep -q 'pytestCommand' <<<"$jf" && c_ok "demo-api calls pytestCommand" || bad "demo-api's Jenkinsfile does not call pytestCommand"
if [[ -z $pin ]]; then
  echo "PENALTY 10 demo-api is unpinned (library default = main): the next commit to platform-lib main reaches it instantly. Pin the release tag."
elif [[ $pin == v1.0.0 ]]; then bad "demo-api is still pinned to v1.0.0, which does not have the step"
elif git -C "$d" rev-parse -q --verify "refs/tags/$pin" >/dev/null; then
  c_ok "demo-api pins platform-lib@$pin (a tag)"
  if ! jenkins_get "/job/demo-api/job/main/lastBuild/consoleText" 2>/dev/null | grep -q "Loading library platform-lib@$pin"; then
    bad "the last main build did not load platform-lib@$pin -- is it a build of your Jenkinsfile?"
  fi
else
  echo "PENALTY 15 demo-api pins platform-lib@$pin, which is a branch, not a release. A branch moves under you; only a tag is a version."
fi

# 4. Behaviour, for real: load the release in a throwaway job and call the step
#    the way the ticket says -- no arguments, no agent -- on main and off main.
if [[ -n $tag ]] && (( fail == 0 )); then
  job_put lib-check-09 "@Library('platform-lib@$tag') _
String onMain = ''
String onFeature = ''
withEnv(['BRANCH_NAME=main']) { onMain = pytestCommand() }
withEnv(['BRANCH_NAME=feature-x']) { onFeature = pytestCommand() }
echo \"CHECK09_MAIN<<\${onMain}>>\"
echo \"CHECK09_FEAT<<\${onFeature}>>\""
  out="$STATE/scratch/check09.console"
  job_run lib-check-09 "$out" 120
  main_cmd=$(sed -n 's/^CHECK09_MAIN<<\(.*\)>>$/\1/p' "$out" | head -1)
  feat_cmd=$(sed -n 's/^CHECK09_FEAT<<\(.*\)>>$/\1/p' "$out" | head -1)
  if [[ $JOB_RESULT != SUCCESS || -z $main_cmd ]]; then
    bad "calling pytestCommand() from $tag failed ($JOB_RESULT). It must work with no arguments and without an agent. Console tail:"
    tail -12 "$out" | sed 's/^/      /'
  else
    ok=1
    grep -q 'python -m pytest' <<<"$main_cmd" && grep -q -- '--junitxml=test-results.xml' <<<"$main_cmd" \
      && grep -q 'pip install -q -r requirements.txt' <<<"$main_cmd" || { bad "on main the step returned: $main_cmd -- not the command the block builds"; ok=0; }
    grep -qE '(^| )(-x|--exitfirst|--maxfail=1)( |$)' <<<"$main_cmd" && { bad "on main the step is fail-fast; main must run the whole suite"; ok=0; }
    grep -qE '(^| )(-x|--exitfirst|--maxfail=1)( |$)' <<<"$feat_cmd" || { bad "off main the step is not fail-fast (-x); the block was"; ok=0; }
    (( ok )) && c_ok "pytestCommand() behaves like the block: main full run, other branches fail fast"
  fi
  job_delete lib-check-09; rm -f "$out"
fi

# 5. The other team did not notice anything.
out="$STATE/scratch/check09.search"
if ! jenkins_get "/job/$SEARCH_JOB/api/json" >/dev/null 2>&1; then
  bad "the search-indexer job is gone from Jenkins"
else
  job_run "$SEARCH_JOB" "$out" 120
  v1=$(awk '$1=="v1.0.0"{print $2}' "$snap")
  if [[ $JOB_RESULT != SUCCESS ]]; then bad "search-indexer (pinned to v1.0.0) is $JOB_RESULT now"
  elif ! grep -q "Loading library platform-lib@v1.0.0" "$out" || ! grep -q "${v1:0:7}" "$out"; then
    bad "search-indexer did not load the original v1.0.0 commit ${v1:0:7}"
  else c_ok "search-indexer, still on v1.0.0 (${v1:0:7}), builds exactly as before"; fi
  rm -f "$out"
fi
exit $fail
