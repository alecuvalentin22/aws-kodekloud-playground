# shellcheck shell=bash
# Helpers for drill 48 only (sourced after lib/common.sh).
NS48=rel-demo
REPO48=payments/rel-pipelines
JOBA=rel-build
JOBB=rel-deploy

# job48 NAME SCRIPTPATH -- create (or update) a Pipeline-from-SCM job on the drill's repo.
job48() {
  local name=$1 path=$2 f="$STATE/scratch/job48-$1.xml"
  mkdir -p "$STATE/scratch"
  cat > "$f" <<EOF2
<?xml version="1.1" encoding="UTF-8"?>
<flow-definition plugin="workflow-job">
  <description>Drill 48 job ($path). Removed by play reset.</description>
  <keepDependencies>false</keepDependencies>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>$GITEA_IN_CLUSTER/$REPO48.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs>
      <branches><hudson.plugins.git.BranchSpec><name>*/main</name></hudson.plugins.git.BranchSpec></branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>$path</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
EOF2
  jenkins_post -H 'Content-Type: application/xml' --data-binary "@$f" "$JENKINS_URL/createItem?name=$name" >/dev/null
  local rc=$?; rm -f "$f"; return $rc
}

# registry_digest TAG -- the digest the registry holds for payments/relsvc:TAG (empty if none).
registry_digest() {
  curl -fsSI -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "$REGISTRY_URL/v2/payments/relsvc/manifests/$1" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
}
