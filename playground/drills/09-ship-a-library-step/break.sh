#!/usr/bin/env bash
# No outage here: a build task. The pilot app carries the copy-pasted test
# block, another team (search-indexer) is pinned to v1.0.0, and the build is GREEN.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"

# A clean start only: leftovers from an earlier round would make the task
# trivial (the step already exists) or the tag check meaningless.
extra=$(git ls-remote --tags "$(repo_url platform/platform-lib)" | awk '{print $2}' | sed 's|refs/tags/||; s|\^{}$||' \
        | sort -u | grep -vxE 'baseline|v1\.0\.0' || true)
[[ -z $extra ]] || { echo "platform-lib already has tags: $extra -- run: play reset"; exit 1; }
d="$STATE/scratch/break09"; rm -rf "$d"; git clone -q "$(repo_url platform/platform-lib)" "$d"
ls "$d/vars" | grep -qx 'pytestCommand.groovy' && { echo "vars/pytestCommand.groovy already on main -- run: play reset"; exit 1; }
rm -rf "$d"

# Snapshot the tags as they are NOW (name, commit). check.sh uses it to see
# whether an existing tag moved; reset.sh keeps exactly these and nothing else.
git ls-remote --tags "$(repo_url platform/platform-lib)" | awk '
  { n=$2; sub("refs/tags/","",n); if (n ~ /\^\{\}$/) { sub(/\^\{\}$/,"",n); peeled[n]=$1 } else direct[n]=$1 }
  END { for (n in direct) print n, (n in peeled ? peeled[n] : direct[n]) }' | sort > "$STATE/drill09.tags"

as_teammate "Sam (payments)" payments/demo-api "Jenkinsfile: test flags, same block as search-indexer and checkout; pin platform-lib" <<'SH'
cat > Jenkinsfile <<'EOF2'
// The whole Jenkinsfile is the standardPipeline call, plus the test command
// every Python team has been copying around.
@Library('platform-lib@v1.0.0') _

// --- test command (same block as search-indexer and checkout) ---
// Fail fast on feature branches so a broken change gets feedback in seconds;
// main runs the whole suite.
def pytestFlags = ['-q', '--junitxml=test-results.xml']
if (env.BRANCH_NAME != 'main') {
    pytestFlags << '-x'
}
String testCmd = "pip install -q -r requirements.txt && python -m pytest ${pytestFlags.join(' ')}"
// --- end of test command ---

standardPipeline(
    app:         'demo-api',
    context:     '.',
    testCommand: testCmd,
)
EOF2
SH

# The other team: a job on its own, pinned to the release everybody has today.
job_put "$SEARCH_JOB" "$SEARCH_SCRIPT"
jenkins_scan
