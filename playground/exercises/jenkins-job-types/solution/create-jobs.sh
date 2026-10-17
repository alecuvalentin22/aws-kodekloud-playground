#!/usr/bin/env bash
# SOLUTION / SHORTCUT -- not the exercise. The exercise is clicking these jobs
# together in the Jenkins UI and understanding each type. This script creates
# the same jobs through the REST API (a job is just config.xml), so you can:
#   - see what the UI saved (compare with `curl .../job/jt-freestyle/config.xml`),
#   - get unstuck on one step:   ./create-jobs.sh freestyle
#   - or check the checker:      ./create-jobs.sh all
#
#   ./create-jobs.sh freestyle|scripted|declarative|multibranch|params|downstream|upstream|matrix|seed|all
#
# Order matters for two of them: jt-downstream must exist and have RUN before
# jt-upstream calls it with a parameter (a parameter only exists after a run).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib.sh
. "$HERE/lib.sh"
GIT_URL="$GITEA_IN_CLUSTER/$REPO.git"
TMP="$STATE/scratch/jt-jobs"; mkdir -p "$TMP"

# put_job NAME FILE -- create the job, or update it if it exists.
put_job() {
  if jenkins_get "/job/$1/api/json" >/dev/null 2>&1; then
    jenkins_post -H 'Content-Type: application/xml' --data-binary "@$2" "$JENKINS_URL/job/$1/config.xml" >/dev/null
    c_ok "updated $1"
  else
    jenkins_post -H 'Content-Type: application/xml' --data-binary "@$2" "$JENKINS_URL/createItem?name=$1" >/dev/null
    c_ok "created $1"
  fi
}

# pipeline_job NAME GROOVYFILE -- a Pipeline job with the script inline.
pipeline_job() {
  python3 - "$HERE/examples/$2" "$TMP/$1.xml" <<'PY'
import html, sys
script = open(sys.argv[1]).read()
open(sys.argv[2], "w").write('''<?xml version="1.1" encoding="UTF-8"?>
<flow-definition plugin="workflow-job">
  <description>Jenkins job-types exercise.</description>
  <keepDependencies>false</keepDependencies>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script>%s</script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
''' % html.escape(script, quote=False))
PY
  put_job "$1" "$TMP/$1.xml"
}

scm_xml() {
  cat <<XML
<scm class="hudson.plugins.git.GitSCM" plugin="git">
    <configVersion>2</configVersion>
    <userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>$GIT_URL</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs>
    <branches><hudson.plugins.git.BranchSpec><name>*/main</name></hudson.plugins.git.BranchSpec></branches>
    <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
    <submoduleCfg class="empty-list"/>
    <extensions/>
  </scm>
XML
}

freestyle() {
  cat > "$TMP/jt-freestyle.xml" <<XML
<?xml version="1.1" encoding="UTF-8"?>
<project>
  <description>(a) Freestyle: everything lives in this form, nothing in git.</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  $(scm_xml)
  <assignedNode>$AGENT_LABEL</assignedNode>
  <canRoam>false</canRoam>
  <disabled>false</disabled>
  <blockBuildWhenDownstreamBuilding>false</blockBuildWhenDownstreamBuilding>
  <blockBuildWhenUpstreamBuilding>false</blockBuildWhenUpstreamBuilding>
  <triggers/>
  <concurrentBuild>false</concurrentBuild>
  <builders><hudson.tasks.Shell><command>sh ./test.sh</command></hudson.tasks.Shell></builders>
  <publishers/>
  <buildWrappers/>
</project>
XML
  put_job jt-freestyle "$TMP/jt-freestyle.xml"
}

multibranch() {
  cat > "$TMP/jt-multibranch.xml" <<XML
<?xml version="1.1" encoding="UTF-8"?>
<org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject plugin="workflow-multibranch">
  <description>(d) Multibranch: one job per branch, discovered from git.</description>
  <displayName>jt-multibranch</displayName>
  <properties/>
  <orphanedItemStrategy class="com.cloudbees.hudson.plugins.folder.computed.DefaultOrphanedItemStrategy" plugin="cloudbees-folder">
    <pruneDeadBranches>true</pruneDeadBranches>
    <daysToKeep>-1</daysToKeep>
    <numToKeep>5</numToKeep>
    <abortBuilds>false</abortBuilds>
  </orphanedItemStrategy>
  <triggers>
    <com.cloudbees.hudson.plugins.folder.computed.PeriodicFolderTrigger plugin="cloudbees-folder">
      <spec>* * * * *</spec>
      <interval>60000</interval>
    </com.cloudbees.hudson.plugins.folder.computed.PeriodicFolderTrigger>
  </triggers>
  <disabled>false</disabled>
  <sources class="jenkins.branch.MultiBranchProject\$BranchSourceList" plugin="branch-api">
    <data>
      <jenkins.branch.BranchSource>
        <source class="jenkins.plugins.git.GitSCMSource" plugin="git">
          <id>jt-multibranch-src</id>
          <remote>$GIT_URL</remote>
          <credentialsId></credentialsId>
          <traits><jenkins.plugins.git.traits.BranchDiscoveryTrait/></traits>
        </source>
        <strategy class="jenkins.branch.DefaultBranchPropertyStrategy"><properties class="empty-list"/></strategy>
      </jenkins.branch.BranchSource>
    </data>
    <owner class="org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject" reference="../.."/>
  </sources>
  <factory class="org.jenkinsci.plugins.workflow.multibranch.WorkflowBranchProjectFactory">
    <owner class="org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject" reference="../.."/>
    <scriptPath>Jenkinsfile</scriptPath>
  </factory>
</org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject>
XML
  put_job jt-multibranch "$TMP/jt-multibranch.xml"
}

seed() {
  cat > "$TMP/jt-seed.xml" <<XML
<?xml version="1.1" encoding="UTF-8"?>
<project>
  <description>(h) Seed job: runs jobs/dsl.groovy and creates jt-dsl-pipeline and jt-dsl-freestyle from it.</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  $(scm_xml)
  <assignedNode>$AGENT_LABEL</assignedNode>
  <canRoam>false</canRoam>
  <disabled>false</disabled>
  <triggers/>
  <concurrentBuild>false</concurrentBuild>
  <builders>
    <javaposse.jobdsl.plugin.ExecuteDslScripts plugin="job-dsl">
      <targets>jobs/dsl.groovy</targets>
      <usingScriptText>false</usingScriptText>
      <sandbox>false</sandbox>
      <ignoreExisting>false</ignoreExisting>
      <ignoreMissingFiles>false</ignoreMissingFiles>
      <failOnMissingPlugin>false</failOnMissingPlugin>
      <failOnSeedCollision>false</failOnSeedCollision>
      <unstableOnDeprecation>false</unstableOnDeprecation>
      <removedJobAction>DELETE</removedJobAction>
      <removedViewAction>IGNORE</removedViewAction>
      <removedConfigFilesAction>IGNORE</removedConfigFilesAction>
      <lookupStrategy>JENKINS_ROOT</lookupStrategy>
    </javaposse.jobdsl.plugin.ExecuteDslScripts>
  </builders>
  <publishers/>
  <buildWrappers/>
</project>
XML
  put_job jt-seed "$TMP/jt-seed.xml"
}

for what in "${@:-all}"; do
  case $what in
    freestyle)   freestyle ;;
    scripted)    pipeline_job jt-scripted scripted.groovy ;;
    declarative) pipeline_job jt-declarative declarative.groovy ;;
    multibranch) multibranch ;;
    params)      pipeline_job jt-params params.groovy ;;
    downstream)  pipeline_job jt-downstream downstream.groovy ;;
    upstream)    pipeline_job jt-upstream upstream.groovy ;;
    matrix)      pipeline_job jt-matrix matrix.groovy ;;
    seed)        seed ;;
    all) "$0" freestyle scripted declarative multibranch params downstream upstream matrix seed ;;
    *) echo "unknown job kind '$what'"; exit 1 ;;
  esac
done
rm -rf "$TMP"
