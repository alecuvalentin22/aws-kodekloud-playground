#!/usr/bin/env bash
# Set up the exercise on the playground:
#   - namespaces cicd-staging and cicd-prod, the Jenkins agent allowed to deploy into
#     them, and a ConfigMap per namespace (MODE=relaxed in staging, strict in prod)
#   - the repo payments/cicd-demo in Gitea (the app, its manifest, a STARTER Jenkinsfile)
#   - the Jenkins job cicd-demo (Pipeline script from SCM, main)
#   - your clone: ~/platform-playground/cicd-demo
# Idempotent: it keeps what exists. Run from the box that runs the playground.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

for t in kubectl jq curl git; do command -v $t >/dev/null || die "$t not on PATH"; done
K get nodes >/dev/null 2>&1 || die "the playground cluster is not reachable (play doctor)"

# 1. Namespaces + the agent's rights in THEM ONLY (it deploys into demo-ci already; nothing cluster-wide).
for spec in "$NS_STAGING:relaxed" "$NS_PROD:strict"; do
  ns=${spec%%:*}; mode=${spec##*:}
  K apply -f - >/dev/null <<EOF2
apiVersion: v1
kind: Namespace
metadata: {name: $ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: deployer, namespace: $ns}
rules:
  - apiGroups: ["apps"]
    resources: [deployments, replicasets]
    verbs: [get, list, watch, create, update, patch]
  - apiGroups: [""]
    resources: [services, pods, configmaps]
    verbs: [get, list, watch, create, update, patch]
  - apiGroups: [""]
    resources: [events]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: jenkins-agent-deployer, namespace: $ns}
subjects:
  - {kind: ServiceAccount, name: jenkins-agent, namespace: jenkins}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: deployer}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: release-config, namespace: $ns}
data: {MODE: "$mode"}
EOF2
  c_ok "namespace $ns (MODE=$mode)"
done

# 2. The repo.
if gitea_api GET "/repos/$REPO" >/dev/null 2>&1; then
  c_dim "  $REPO exists, kept"
else
  gitea_api POST /orgs/payments/repos '{"name":"cicd-demo","private":false,"description":"Full CI/CD exercise"}' >/dev/null
  d="$STATE/scratch/seed-cicd"; rm -rf "$d"; mkdir -p "$d"
  cp -R "$HERE/app/." "$d/"
  git -C "$d" init -q -b main
  git -C "$d" add -A
  git -C "$d" -c user.name="Platform team" -c user.email="platform@playground.local" commit -q -m "cicd-demo: app, manifest, starter Jenkinsfile"
  git -C "$d" push -q "$(repo_url "$REPO")" main
  rm -rf "$d"
  c_ok "created $REPO"
fi

# 3. The job.
if jenkins_get "/job/$JOB/api/json" >/dev/null 2>&1; then
  c_dim "  job $JOB exists, kept"
else
  f="$STATE/scratch/job-cicd.xml"; mkdir -p "$STATE/scratch"
  cat > "$f" <<EOF2
<?xml version="1.1" encoding="UTF-8"?>
<flow-definition plugin="workflow-job">
  <description>Full CI/CD exercise: build, test, stage, approve, prod. Removed by cleanup.sh.</description>
  <keepDependencies>false</keepDependencies>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>$GITEA_IN_CLUSTER/$REPO.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs>
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
  jenkins_post -H 'Content-Type: application/xml' --data-binary "@$f" "$JENKINS_URL/createItem?name=$JOB" >/dev/null
  rm -f "$f"
  c_ok "created Jenkins job $JOB"
fi

# 4. Your clone.
w="$WORK/cicd-demo"
if [[ ! -d $w/.git ]]; then
  cred_file="$STATE/git-credentials"
  git clone -q "http://$GITEA_USER@localhost:30300/$REPO.git" "$w" -c credential.helper="store --file=$cred_file"
  git -C "$w" config user.name "You (platform team)"
  git -C "$w" config user.email "you@playground.local"
fi
c_ok "your clone: $w"
echo "  Jenkins $JENKINS_URL/job/$JOB   Gitea $GITEA_URL/$REPO"
