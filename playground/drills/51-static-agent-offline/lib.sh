# shellcheck shell=bash
# Helpers for the static-agent drills 51-53 (sourced after lib/common.sh). The
# same file is kept in each drill directory so a drill stays self-contained.

SA="$PG_ROOT/setup/static-agent.sh"
AGENT_NODE=static-01
AGENT_CONTAINER=pg-static-01
AGENT_WS=/home/jenkins/agent
# Gitea as the static agent sees it. The agent is a container on the kind
# network, OUTSIDE the cluster, so gitea.git.svc.cluster.local does not resolve
# for it; the NodePort on the kind node does. (Pods use the in-cluster name.)
STATIC_GIT="http://$CLUSTER-control-plane:30300"
BASELINE_FILE="$STATE/static-drills.baseline"

jg() { curl -fsSg -u "admin:$JENKINS_PASSWORD" "$JENKINS_URL$1"; }

# --- the agent: remember how it was before the first static drill, restore that ---
# WAS_UP=1: the agent was running (the player set it up) -> reset puts it back to
# its baseline. WAS_UP=0: the drill brought it up -> reset takes it down again.
agent_for_drill() {
  if [[ ! -f $BASELINE_FILE ]]; then
    if [[ "$(docker inspect -f '{{.State.Status}}' "$AGENT_CONTAINER" 2>/dev/null)" == running ]]
    then echo WAS_UP=1; else echo WAS_UP=0; fi > "$BASELINE_FILE"
  fi
  # shellcheck disable=SC1090
  source "$BASELINE_FILE"
  if (( WAS_UP )); then bash "$SA" reset; else bash "$SA" up; fi
}
agent_restore_baseline() {
  [[ -f $BASELINE_FILE ]] || return 0
  # shellcheck disable=SC1090
  source "$BASELINE_FILE"
  if (( WAS_UP )); then bash "$SA" reset; else bash "$SA" down; fi
  rm -f "$BASELINE_FILE"
}
agent_node_json() { jg "/computer/$AGENT_NODE/api/json?tree=offline,temporarilyOffline,offlineCauseReason,idle" 2>/dev/null; }
agent_ws_exec() { docker exec "$AGENT_CONTAINER" bash -c "$1"; }   # run in the agent container

# --- Gitea: a team's repo with a Jenkinsfile ------------------------------------------
# repo_seed ORG REPO SRC_DIR "commit message" -- (re)creates the repo, one commit on main.
repo_seed() {
  local org=$1 repo=$2 src=$3 msg=$4 d="$STATE/scratch/seed-$1-$2"
  gitea_api GET "/orgs/$org" >/dev/null 2>&1 || \
    gitea_api POST /orgs "{\"username\":\"$org\",\"visibility\":\"public\"}" >/dev/null
  gitea_api POST "/orgs/$org/repos" "{\"name\":\"$repo\",\"private\":false,\"default_branch\":\"main\"}" >/dev/null
  rm -rf "$d"; mkdir -p "$d"; cp -R "$src/." "$d/"
  git -C "$d" init -q -b main
  git -C "$d" add -A
  git -C "$d" -c user.name="${5:-Team}" -c user.email="teammate@playground.local" commit -q -m "$msg"
  git -C "$d" push -q "$(repo_url "$org/$repo")" main
  rm -rf "$d"
}
repo_clone_for_player() {   # same setup as setup/up.sh gives the other clones
  local org=$1 repo=$2
  [[ -d $WORK/$repo/.git ]] && return 0
  mkdir -p "$WORK"
  git clone -q "$(repo_url "$org/$repo")" "$WORK/$repo"
  git -C "$WORK/$repo" remote set-url origin "http://$GITEA_USER@localhost:30300/$org/$repo.git"
  git -C "$WORK/$repo" config credential.helper "store --file=$STATE/git-credentials"
  git -C "$WORK/$repo" config user.name "You (platform team)"
  git -C "$WORK/$repo" config user.email "you@playground.local"
}
repo_drop() {   # repo_drop ORG REPO: the repo, the org if now empty, the player's clone if it is that repo
  gitea_api DELETE "/repos/$1/$2" >/dev/null 2>&1 || true
  gitea_api DELETE "/orgs/$1" >/dev/null 2>&1 || true
  if [[ -d $WORK/$2/.git ]] && git -C "$WORK/$2" remote get-url origin 2>/dev/null | grep -q "$1/$2"; then
    rm -rf "${WORK:?}/$2"
  fi
}

# --- Jenkins: a pipeline job whose Jenkinsfile is read from main of a Gitea repo ----------
# job_scm NAME ORG/REPO DESCRIPTION -- create, or update in place.
job_scm() {
  local name=$1 repo=$2 desc=$3 f="$STATE/scratch/job-$1.xml"
  mkdir -p "$STATE/scratch"
  cat > "$f" <<XML
<?xml version="1.1" encoding="UTF-8"?>
<flow-definition plugin="workflow-job">
  <description>$desc</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>$STATIC_GIT/$repo.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs>
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
XML
  if jenkins_get "/job/$name/api/json" >/dev/null 2>&1; then
    jenkins_post -H 'Content-Type: application/xml' --data-binary "@$f" "$JENKINS_URL/job/$name/config.xml" >/dev/null
  else
    jenkins_post -H 'Content-Type: application/xml' --data-binary "@$f" "$JENKINS_URL/createItem?name=$name" >/dev/null
  fi
  local rc=$?; rm -f "$f"; return $rc
}
job_drop() {   # stop what runs (kill what will not stop), then delete
  jenkins_get "/job/$1/api/json" >/dev/null 2>&1 || return 0
  jenkins_groovy "
def j = jenkins.model.Jenkins.get()
def p = j.getItem('$1')
p.builds.each { b -> if (b.isBuilding()) { b.doStop() } }
j.queue.items.findAll { it.task.name == '$1' }.each { j.queue.cancel(it) }
for (i in 0..<20) { if (!p.builds.any { it.isBuilding() }) { break }; sleep(1000) }
p.builds.each { b -> if (b.isBuilding()) { b.doKill() } }
sleep(1000)
p.delete()
println 'deleted'" >/dev/null 2>&1 || true
}

# build_start JOB -> prints the number the new build will get (it may be queued)
build_start() {
  local n; n=$(jg "/job/$1/api/json?tree=nextBuildNumber" | jq -r .nextBuildNumber) || return 1
  jenkins_post "$JENKINS_URL/job/$1/build?delay=0" >/dev/null || return 1
  echo "$n"
}
# build_wait JOB N SECONDS -> prints RESULT (SUCCESS, FAILURE, ...), RUNNING, or QUEUED (never started)
build_wait() {
  local job=$1 n=$2 limit=${3:-120} t0 b; t0=$(date +%s)
  while (( $(date +%s) - t0 < limit )); do
    b=$(jg "/job/$job/$n/api/json?tree=building,result" 2>/dev/null || true)
    if [[ -n $b ]]; then
      [[ $(jq -r .building <<<"$b") == false ]] && { jq -r '.result // "UNKNOWN"' <<<"$b"; return 0; }
    fi
    sleep 2
  done
  [[ -n ${b:-} ]] && echo RUNNING || echo QUEUED
}
# build_run JOB [seconds] -- start a build and wait; sets BUILD_N and BUILD_RESULT (SUCCESS, FAILURE, ...,
# RUNNING or QUEUED when it did not finish). Not for command substitution (it sets variables).
# If the build never gets an executor although the node is online and idle (seen rarely as a Pipeline
# queue item "Stopping part of <job> #N" blocked next to an idle executor), it is stopped and started once more.
build_run() {
  local job=$1 limit=${2:-120} attempt n t0 b nj
  for attempt in 1 2; do
    n=$(build_start "$job") || return 1
    t0=$(date +%s)
    while (( $(date +%s) - t0 < limit )); do
      b=$(jg "/job/$job/$n/api/json?tree=building,result" 2>/dev/null || true)
      if [[ -n $b && $(jq -r .building <<<"$b") == false ]]; then BUILD_N=$n; BUILD_RESULT=$(jq -r '.result // "UNKNOWN"' <<<"$b"); return 0; fi
      if (( attempt == 1 && $(date +%s) - t0 > 40 )) && ! build_console "$job" "$n" | grep -q "Running on"; then
        nj=$(agent_node_json)
        if [[ $(jq -r .offline <<<"$nj") == false && $(jq -r .idle <<<"$nj") == true ]]; then
          echo "  (build #$n never got the idle executor; stopping it and starting it again)" >&2
          build_abort "$job" "$n"; sleep 3; continue 2
        fi
      fi
      sleep 2
    done
    BUILD_N=$n; BUILD_RESULT=$([[ -n ${b:-} ]] && echo RUNNING || echo QUEUED); return 0
  done
}

# build_abort JOB N -- stop a build the check started and gave up on, so it cannot block the next check
build_abort() { jenkins_post "$JENKINS_URL/job/$1/$2/stop" >/dev/null 2>&1 || true; jenkins_post "$JENKINS_URL/job/$1/$2/kill" >/dev/null 2>&1 || true; }
build_console() { jg "/job/$1/$2/consoleText" 2>/dev/null || true; }
