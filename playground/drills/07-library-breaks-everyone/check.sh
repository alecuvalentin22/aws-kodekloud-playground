#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
assert_main_green_since "$DRILL_STARTED" || exit 1

# The other two teams never edited their Jenkinsfiles. Is the library's main
# usable by an UNCHANGED caller again? (Making only demo-api pass is not a fix.)
lib=$(curl -fsS "$GITEA_URL/platform/platform-lib/raw/branch/main/vars/standardPipeline.groovy")
if grep -q "cfg.path *?: error" <<<"$lib"; then
  c_bad "platform-lib main still REQUIRES 'path' -- search and checkout are still red"; exit 1
fi
c_ok "platform-lib main accepts existing callers again"

bad=$(cat "$STATE/drill07.bad-sha" 2>/dev/null)
d="$STATE/scratch/check07"; rm -rf "$d"; git clone -q "$(repo_url platform/platform-lib)" "$d"
if [[ -n $bad ]] && ! git -C "$d" merge-base --is-ancestor "$bad" HEAD 2>/dev/null; then
  echo "PENALTY 15 You rewrote main's history on a shared repo. Everyone with a clone now has a diverged main; git revert says the same thing without that."
else
  c_ok "fixed forward (history intact)"
fi
rm -rf "$d"

jf=$(curl -fsS "$GITEA_URL/payments/demo-api/raw/branch/main/Jenkinsfile")
if grep -q "platform-lib@" <<<"$jf"; then
  c_ok "demo-api pins the library: $(grep -o "platform-lib@[^']*" <<<"$jf")"
else
  echo "PENALTY 10 Still unpinned: the next library commit to main reaches every team instantly again. Your lead asked what stops a repeat."
fi
