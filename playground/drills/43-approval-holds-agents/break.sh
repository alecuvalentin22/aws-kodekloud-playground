#!/usr/bin/env bash
# The fulfilment team adds a release-manager approval (`input`) to order-router
# INSIDE the stage that holds an agent pod, with no timeout. Two builds park at
# it overnight-style. The Kubernetes cloud allows 2 agent pods (a platform
# change), so the next team's build queues behind them.
#
# Everything this creates is removed by reset.sh (job, repo, clone, cap).
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
ORG=fulfilment REPO=order-router JOB=order-router
STATE_FILE="$STATE/drill43.state"
CAP_LOW=2
GITEA_INTERNAL=http://gitea.git.svc.cluster.local:3000

bash "$(dirname "$0")/reset.sh"        # a clean slate, whatever a failed earlier run left

jg() { curl -fsSg -u "admin:$JENKINS_PASSWORD" "$JENKINS_URL$1"; }   # -g: allow [] in ?tree=

# --- 1. the team's repo: a working pipeline, then Dana's change -----------------
gitea_api GET "/orgs/$ORG" >/dev/null 2>&1 || \
  gitea_api POST /orgs "{\"username\":\"$ORG\",\"visibility\":\"public\"}" >/dev/null
gitea_api POST "/orgs/$ORG/repos" "{\"name\":\"$REPO\",\"private\":false,\"default_branch\":\"main\"}" >/dev/null

seed="$STATE/scratch/seed-$ORG-$REPO"; rm -rf "$seed"; mkdir -p "$seed"
cat > "$seed/Jenkinsfile" <<'JF'
// order-router (fulfilment team): build, then roll out to staging.
pipeline {
    agent {
        kubernetes {
            yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: tools
      image: python:3.13.16-slim
      command: [sleep]
      args: [infinity]
      resources:
        requests: {cpu: 100m, memory: 128Mi}
        limits: {memory: 512Mi}
'''
            defaultContainer 'tools'
        }
    }
    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }
    stages {
        stage('Build') {
            steps {
                sh 'echo "building order-router"; sleep 5'
            }
        }
        stage('Deploy to staging') {
            steps {
                sh 'echo "rolling out to staging"'
            }
        }
    }
}
JF
git -C "$seed" init -q -b main
git -C "$seed" add -A
git -C "$seed" -c user.name="Dana (fulfilment)" -c user.email="teammate@playground.local" \
  commit -q -m "Jenkinsfile: build and stage order-router"
git -C "$seed" push -q "$(repo_url "$ORG/$REPO")" main
rm -rf "$seed"

as_teammate "Dana (fulfilment)" "$ORG/$REPO" "Jenkinsfile: release-manager approval before prod (compliance)" <<'SH'
python3 - <<'PY'
p = "Jenkinsfile"
s = open(p).read()
old = """        stage('Deploy to staging') {
            steps {
                sh 'echo "rolling out to staging"'
            }
        }
"""
assert old in s
new = old + """        stage('Deploy to prod') {
            steps {
                input message: 'Release order-router to prod?', ok: 'Release'
                sh 'echo "rolling out to prod"'
            }
        }
"""
open(p, "w").write(s.replace(old, new))
PY
grep -q "input message" Jenkinsfile
SH

# --- 2. the candidate's clone, set up the way setup/up.sh sets up the others ------
if [[ ! -d $WORK/$REPO/.git ]]; then
  mkdir -p "$WORK"
  git clone -q "$(repo_url "$ORG/$REPO")" "$WORK/$REPO"
  git -C "$WORK/$REPO" remote set-url origin "http://$GITEA_USER@localhost:30300/$ORG/$REPO.git"
  git -C "$WORK/$REPO" config credential.helper "store --file=$STATE/git-credentials"
  git -C "$WORK/$REPO" config user.name "You (platform team)"
  git -C "$WORK/$REPO" config user.email "you@playground.local"
fi

# --- 3. the Jenkins job, seeded with Job DSL like demo-api -------------------------
jenkins_groovy "
import javaposse.jobdsl.dsl.DslScriptLoader
import javaposse.jobdsl.plugin.JenkinsJobManagement
new DslScriptLoader(new JenkinsJobManagement(System.out, [:], new File('.'))).runScript('''
multibranchPipelineJob('$JOB') {
  displayName('order-router (fulfilment team)')
  description('Seeded by Job DSL. Polls Gitea every minute.')
  branchSources {
    git {
      id('order-router-src')
      remote('$GITEA_INTERNAL/$ORG/$REPO.git')
    }
  }
  factory { workflowBranchProjectFactory { scriptPath('Jenkinsfile') } }
  triggers { periodicFolderTrigger { interval('1m') } }
  orphanedItemStrategy { discardOldItems { numToKeep(5) } }
}
''')
println 'job created'" | grep -q 'job created'

# --- 4. the platform change: the cloud's concurrency cap -------------------------
CAP_ORIG=$(jenkins_groovy "
import jenkins.model.Jenkins
def k = Jenkins.get().clouds.getByName('kubernetes')
print k.containerCapStr
k.setContainerCapStr('$CAP_LOW')
Jenkins.get().save()")
[[ $CAP_ORIG =~ ^[0-9]+$ ]] || die "could not read the cloud's current cap ('$CAP_ORIG')"
printf 'CAP_ORIG=%s\nCAP_LOW=%s\nBAD_BUILDS="1 2"\n' "$CAP_ORIG" "$CAP_LOW" > "$STATE_FILE"

# --- 5. two builds, both parked at the approval -----------------------------------
# Wait for the scan to find main and for its first build to start...
for _ in $(seq 1 60); do
  jg "/job/$JOB/job/main/api/json?tree=nextBuildNumber" 2>/dev/null | jq -e '.nextBuildNumber >= 2' >/dev/null 2>&1 && break
  jenkins_post "$JENKINS_URL/job/$JOB/build?delay=0" >/dev/null 2>&1 || true
  sleep 5
done
# ...and then a second one: Dana re-ran it "to see if it was stuck".
jenkins_post "$JENKINS_URL/job/$JOB/job/main/build?delay=0" >/dev/null

parked() {
  jg "/job/$JOB/job/main/$1/wfapi/describe" 2>/dev/null | jq -r '.status // empty'
}
for _ in $(seq 1 90); do
  [[ $(parked 1) == PAUSED_PENDING_INPUT && $(parked 2) == PAUSED_PENDING_INPUT ]] && break
  sleep 5
done
[[ $(parked 1) == PAUSED_PENDING_INPUT && $(parked 2) == PAUSED_PENDING_INPUT ]] \
  || die "the two order-router builds never reached the approval"

# --- 6. and now Sam's build, which has no pod to run in -----------------------------
jenkins_post "$JENKINS_URL/job/demo-api/job/main/build?delay=0" >/dev/null || true
sleep 20
