#!/usr/bin/env bash
# Two teams, two Jenkins folders, ONE global credential (artifactory-token) that
# both pipelines use. "Jordan" then moves it into the payments folder for least
# privilege. payments keeps working; risk had been relying on the global one
# and now fails with "Could not find credentials entry".
#
# Everything this creates is removed by reset.sh.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
GITEA_INTERNAL=http://gitea.git.svc.cluster.local:3000
HANDOFF="$WORK/handoff/risk-artifactory-token.txt"

bash "$(dirname "$0")/reset.sh"        # a clean slate, whatever a failed earlier run left

jg() { curl -fsSg -u "admin:$JENKINS_PASSWORD" "$JENKINS_URL$1"; }   # -g: allow [] in ?tree=
sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | awk '{print $1}'; }

# A Groovy script that carries a secret goes to the script console from a 600
# file, not from the command line.
groovy_file() {
  local f; f=$(mktemp "$STATE/scratch/groovy.XXXXXX"); chmod 600 "$f"
  cat > "$f"
  jenkins_post --data-urlencode "script@$f" "$JENKINS_URL/scriptText"; local rc=$?
  rm -f "$f"; return $rc
}

jenkinsfile() {   # jenkinsfile <app>
  cat <<JF
// $1: publish the build to Artifactory.
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
        requests: {cpu: 50m, memory: 64Mi}
        limits: {memory: 256Mi}
'''
            defaultContainer 'tools'
        }
    }
    options {
        timestamps()
        timeout(time: 10, unit: 'MINUTES')
    }
    stages {
        stage('Build') {
            steps {
                sh 'echo "building $1"'
            }
        }
        stage('Publish') {
            steps {
                withCredentials([string(credentialsId: 'artifactory-token', variable: 'ARTIFACTORY_TOKEN')]) {
                    sh '''
                        test -n "\$ARTIFACTORY_TOKEN"
                        echo "publishing $1 to Artifactory with a \${#ARTIFACTORY_TOKEN}-character token"
                    '''
                }
            }
        }
    }
}
JF
}

seed_repo() {   # seed_repo <org/repo> <app> <author>
  local full=$1 app=$2 who=$3 d
  d="$STATE/scratch/seed-$(echo "$full" | tr / _)"; rm -rf "$d"; mkdir -p "$d"
  jenkinsfile "$app" > "$d/Jenkinsfile"
  git -C "$d" init -q -b main
  git -C "$d" add -A
  git -C "$d" -c user.name="$who" -c user.email="teammate@playground.local" \
    commit -q -m "Jenkinsfile: build and publish $app"
  git -C "$d" push -q "$(repo_url "$full")" main
  rm -rf "$d"
}

# --- 1. the two tokens. Only their hashes are kept; risk's own is handed over as a file. ----
payments_tok=$(openssl rand -hex 20)
risk_tok=$(openssl rand -hex 20)
umask 077
mkdir -p "$WORK/handoff"
printf '%s\n' "$risk_tok" > "$HANDOFF"
printf 'RISK_SHA=%s\n' "$(printf '%s' "$risk_tok" | sha256)" > "$STATE/drill44.state"
umask 022

# --- 2. repos --------------------------------------------------------------------------------
gitea_api GET /orgs/risk >/dev/null 2>&1 || \
  gitea_api POST /orgs '{"username":"risk","visibility":"public"}' >/dev/null
gitea_api POST /orgs/payments/repos '{"name":"ledger-export","private":false,"default_branch":"main"}' >/dev/null
gitea_api POST /orgs/risk/repos '{"name":"fraud-scorer","private":false,"default_branch":"main"}' >/dev/null
seed_repo payments/ledger-export ledger-export "Priya (payments)"
seed_repo risk/fraud-scorer fraud-scorer "Priya (risk)"

# --- 3. folders and jobs, seeded with Job DSL ---------------------------------------------------
jenkins_groovy "
import javaposse.jobdsl.dsl.DslScriptLoader
import javaposse.jobdsl.plugin.JenkinsJobManagement
new DslScriptLoader(new JenkinsJobManagement(System.out, [:], new File('.'))).runScript('''
folder('payments') { description('payments team') }
folder('risk') { description('risk team') }
[['payments', 'ledger-export'], ['risk', 'fraud-scorer']].each { team, app ->
  multibranchPipelineJob(team + '/' + app) {
    description('Seeded by Job DSL. Polls Gitea every minute.')
    branchSources {
      git {
        id(app + '-src')
        remote('$GITEA_INTERNAL/' + team + '/' + app + '.git')
      }
    }
    factory { workflowBranchProjectFactory { scriptPath('Jenkinsfile') } }
    triggers { periodicFolderTrigger { interval('1m') } }
    orphanedItemStrategy { discardOldItems { numToKeep(5) } }
  }
}
''')
println 'jobs created'" | grep -q 'jobs created'

# --- 4. the shared credential, global, the way it had always been ---------------------------------
groovy_file <<GV | grep -q 'created'
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.*
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
import hudson.util.Secret
SystemCredentialsProvider.getInstance().getStore().addCredentials(Domain.global(),
  new StringCredentialsImpl(CredentialsScope.GLOBAL, 'artifactory-token', 'Artifactory deploy token', Secret.fromString('$payments_tok')))
println 'created'
GV
unset payments_tok risk_tok

result_of() {   # result_of <team/app> <build number>: RUNNING, a result, or none
  jg "/job/${1%%/*}/job/${1##*/}/job/main/$2/api/json?tree=result,building" 2>/dev/null \
    | jq -r 'if .building then "RUNNING" else (.result // "none") end' 2>/dev/null || echo none
}
wait_result() {   # wait_result <team/app> <n> <seconds>: returns once the build has a final result
  local end=$(( $(date +%s) + $3 )) r
  while (( $(date +%s) < end )); do
    r=$(result_of "$1" "$2")
    case $r in none|RUNNING) sleep 4 ;; *) echo "$r"; return 0 ;; esac
  done
  echo timeout
}

# --- 5. both pipelines green on the global credential -------------------------------------------------
for app in payments/ledger-export risk/fraud-scorer; do
  for _ in $(seq 1 40); do
    [[ $(result_of "$app" 1) != none ]] && break
    jenkins_post "$JENKINS_URL/job/${app%%/*}/job/${app##*/}/build?delay=0" >/dev/null 2>&1 || true
    sleep 5
  done
done
for app in payments/ledger-export risk/fraud-scorer; do
  [[ $(wait_result "$app" 1 240) == SUCCESS ]] || die "baseline build of $app did not go green"
done

# --- 6. Jordan's change: the credential moves into the payments folder -------------------------------------
groovy_file <<'GV' | grep -q 'moved'
import jenkins.model.Jenkins
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.*
import com.cloudbees.hudson.plugins.folder.properties.FolderCredentialsProvider.FolderCredentialsProperty
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
def store = SystemCredentialsProvider.getInstance().getStore()
def old = store.getCredentials(Domain.global()).find { it.id == 'artifactory-token' }
def secret = old.secret
store.removeCredentials(Domain.global(), old)
def folder = Jenkins.get().getItem('payments')
def prop = folder.properties.get(FolderCredentialsProperty)
if (prop == null) { prop = new FolderCredentialsProperty(new DomainCredentials[0]); folder.addProperty(prop) }
prop.store.addCredentials(Domain.global(),
  new StringCredentialsImpl(CredentialsScope.GLOBAL, 'artifactory-token', 'Artifactory deploy token (payments)', secret))
println 'moved'
GV

# --- 7. the morning after: payments still green, risk red ------------------------------------------------------
for app in payments/ledger-export risk/fraud-scorer; do
  jenkins_post "$JENKINS_URL/job/${app%%/*}/job/${app##*/}/job/main/build?delay=0" >/dev/null
done
[[ $(wait_result payments/ledger-export 2 240) == SUCCESS ]] || die "payments/ledger-export should still be green"
[[ $(wait_result risk/fraud-scorer 2 240) == FAILURE ]] || die "risk/fraud-scorer should have failed"
jg /job/risk/job/fraud-scorer/job/main/2/consoleText | grep -q "Could not find credentials entry with ID 'artifactory-token'" \
  || die "risk/fraud-scorer failed, but not with the missing-credential error"
