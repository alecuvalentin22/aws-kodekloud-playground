#!/usr/bin/env bash
# The classic parameter trap, set up like it happens: the release job is a
# Pipeline-from-SCM whose Jenkinsfile declares its own parameters {}. It ran
# once with the OLD names (ENV, TAG), so Jenkins' form offers those. Then Priya
# merged a rename (TARGET_ENV, IMAGE_TAG, + DRY_RUN) and nobody ran the job
# since: the form is stale, params.TARGET_ENV is null, and the pipeline turns
# "nothing given" into staging/latest without a word.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"

if gitea_api GET "/repos/$REPO47" >/dev/null 2>&1 || jenkins_get "/job/$JOB47/api/json" >/dev/null 2>&1; then
  echo "drill 47 leftovers exist ($REPO47 / $JOB47) -- run: play reset"; exit 1
fi

# 1. The repo, as the payments team had it: v1 of the Jenkinsfile.
gitea_api POST /orgs/payments/repos '{"name":"release-job","private":false,"description":"payments release job (drill 47)"}' >/dev/null
d="$STATE/scratch/seed47"; rm -rf "$d"; mkdir -p "$d"
cat > "$d/Jenkinsfile" <<'EOF2'
// payments release job: promote a demo-api image tag to an environment.
// (The apply step is only echoed in this playground; the point is the job.)
pipeline {
    agent none
    parameters {
        choice(name: 'ENV', choices: ['staging', 'prod'], description: 'Where to release')
        string(name: 'TAG', defaultValue: '', description: 'demo-api image tag, e.g. main-1a2b3c4d-12')
    }
    stages {
        stage('Release') {
            steps {
                script {
                    String target = params.ENV ?: 'staging'
                    String tag = params.TAG ?: 'latest'
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${target} ${tag}"
                    echo "Releasing demo-api:${tag} to ${target}"
                    echo "RELEASE env=${target} tag=${tag}"
                }
            }
        }
    }
}
EOF2
git -C "$d" init -q -b main
git -C "$d" add -A
git -C "$d" -c user.name="Platform team" -c user.email="platform@playground.local" commit -q -m "Release job: ENV + TAG"
git -C "$d" push -q "$(repo_url "$REPO47")" main
rm -rf "$d"

# 2. The Jenkins job: Pipeline script from SCM.
f="$STATE/scratch/job47.xml"; mkdir -p "$STATE/scratch"
cat > "$f" <<EOF2
<?xml version="1.1" encoding="UTF-8"?>
<flow-definition plugin="workflow-job">
  <description>Releases a demo-api image tag to an environment. Drill 47; removed by play reset.</description>
  <keepDependencies>false</keepDependencies>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>$GITEA_IN_CLUSTER/$REPO47.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs>
      <branches><hudson.plugins.git.BranchSpec><name>*/main</name></hudson.plugins.git.BranchSpec></branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
EOF2
jenkins_post -H 'Content-Type: application/xml' --data-binary "@$f" "$JENKINS_URL/createItem?name=$JOB47" >/dev/null
rm -f "$f"

# 3. Its one and only run so far: v1 declares ENV and TAG, so Jenkins now offers them.
jenkins_post "$JENKINS_URL/job/$JOB47/build?delay=0" >/dev/null
for _ in $(seq 1 45); do
  r=$(jenkins_get "/job/$JOB47/1/api/json?tree=building,result" 2>/dev/null || true)
  [[ -n $r && $(jq -r .building <<<"$r") == false ]] && break
  sleep 2
done
[[ $(jq -r '.result' <<<"$r") == SUCCESS ]] || { echo "the v1 run of $JOB47 did not succeed"; exit 1; }
[[ "$(release_param_names)" == "ENV TAG" ]] || { echo "Jenkins did not register ENV/TAG ($(release_param_names))"; exit 1; }

# 4. Tuesday: Priya renames the parameters. Nobody runs the job afterwards.
as_teammate "Priya (payments)" "$REPO47" "Release job: TARGET_ENV / IMAGE_TAG to match the Slack bot, add DRY_RUN" <<'SH'
cat > Jenkinsfile <<'EOF2'
// payments release job: promote a demo-api image tag to an environment.
// (The apply step is only echoed in this playground; the point is the job.)
pipeline {
    agent none
    parameters {
        choice(name: 'TARGET_ENV', choices: ['staging', 'prod'], description: 'Where to release')
        string(name: 'IMAGE_TAG', defaultValue: '', description: 'demo-api image tag, e.g. main-1a2b3c4d-12')
        booleanParam(name: 'DRY_RUN', defaultValue: false, description: 'Print the release, do not apply it')
    }
    stages {
        stage('Plan') {
            steps {
                script {
                    String target = params.TARGET_ENV ?: 'staging'
                    String tag = params.IMAGE_TAG ?: 'latest'
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${target} ${tag}"
                    env.RELEASE_ENV = target
                    env.RELEASE_TAG = tag
                    echo "Releasing demo-api:${tag} to ${target}"
                }
            }
        }
        stage('Apply') {
            steps {
                echo "RELEASE env=${env.RELEASE_ENV} tag=${env.RELEASE_TAG} dry_run=${params.DRY_RUN ? 'true' : 'false'}"
            }
        }
    }
}
EOF2
SH

# 5. The player's clone, like up.sh makes them.
cred_file="$STATE/git-credentials"
w="$WORK/release-job"; rm -rf "$w"
git clone -q "http://$GITEA_USER@localhost:30300/$REPO47.git" "$w" -c credential.helper="store --file=$cred_file"
git -C "$w" config user.name "You (platform team)"
git -C "$w" config user.email "you@playground.local"
