#!/usr/bin/env bash
# A STATIC (permanent) Jenkins agent for the playground, next to the dynamic
# Kubernetes-pod agents it already has. OPT-IN: setup/up.sh does not run this.
#
#   playground/setup/static-agent.sh up       register node "static-01" + start its container (idempotent)
#   playground/setup/static-agent.sh status   container, node, labels, workspace disk
#   playground/setup/static-agent.sh reset    force node + container back to the baseline (drills use this)
#   playground/setup/static-agent.sh down     remove the container, the node and the state (clean)
#   playground/setup/static-agent.sh recreate re-create the container from the state file, as a reboot would
#
# What it is
#   A Docker container (jenkins/inbound-agent, JDK 21, pinned by tag AND digest)
#   on the same Docker network as kind, named pg-static-01, 512 MB, 1 CPU. It
#   connects OUT to the controller over WebSocket with the node's secret, like a
#   build box behind a firewall that only allows outbound HTTP(S). Node label
#   "static linux", 1 executor, "only jobs whose label matches" (EXCLUSIVE).
#
# Why an inbound (WebSocket) agent and not an SSH agent
#   An SSH agent needs the ssh-slaves plugin and this Jenkins does not have it
#   (plugins are pinned in ci/jenkins/values.yaml; adding one means a chart
#   change and a controller restart). WebSocket needs nothing but core, it is
#   what you would use when the controller sits behind an ingress, and the
#   container stays outside the cluster, which is the point of "static":
#   a machine that exists on its own, with its own disk and its own lifetime.
#   The honest trade-off: with SSH the controller holds a key to the machine;
#   with inbound the machine holds the node's secret.
#
# The workspace root /home/jenkins/agent is a SIZE-LIMITED tmpfs
# (STATIC_WS_SIZE, default 96m): filling it can never touch the host's disk
# (drill 53 relies on that). It survives builds and agent reconnects, not
# a container re-creation, which is what `reset` does on purpose.
#
# State (never in git): $STATE/static-agent/agent.env, mode 600, holds the
# node secret. Passed to Docker with --env-file, so it is not on a command
# line (`ps`). `docker inspect` shows it to whoever may use Docker anyway.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

AGENT_IMAGE='jenkins/inbound-agent:3391.va_37fa_a_305d6d-3-jdk21@sha256:6a31d728c22ad74adbb6b9a1a210eb9ec2599f644b95edd7f8a3b8a71d20772c'  # released 2026-09-18
NODE=static-01
CONTAINER=pg-static-01
LABELS='static linux'
REMOTE_FS=/home/jenkins/agent
EXECUTORS=1
WS_SIZE=${STATIC_WS_SIZE:-96m}
MEM=${STATIC_MEM:-512m}
# kind names its node <cluster>-control-plane and publishes the NodePorts on it,
# so from a container on the kind network the controller and Gitea are here:
KIND_HOST="$CLUSTER-control-plane"
AGENT_JENKINS_URL="http://$KIND_HOST:30094"
SDIR="$STATE/static-agent"
ENVF="$SDIR/agent.env"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

preflight() {
  docker info >/dev/null 2>&1 || die "Docker is not running"
  load_creds
  jenkins_get /api/json >/dev/null 2>&1 || die "Jenkins not answering on $JENKINS_URL (setup/up.sh)"
  [[ -n "$(docker ps -q -f "name=^${KIND_HOST}\$")" ]] || die "kind node $KIND_HOST is not running (setup/up.sh)"
}

# --- the node in Jenkins ----------------------------------------------------------
# register_node [force]: create the node if absent; with "force", delete and
# create it again so it is exactly the baseline (what drills' reset needs).
# The disk thresholds are per node and scaled to the 96 MB workspace: Jenkins'
# default (1 GiB free) would mark any 96 MB filesystem offline from the start.
# Order of the constructor: disk, temp, disk warning, temp warning. Workspace:
# offline under 16 MiB free, warning under 32 MiB. /tmp: 64 MiB / 128 MiB.
register_node() {
  local force=${1:-no}
  jenkins_groovy "
import jenkins.model.*
import hudson.model.*
import hudson.slaves.*
import hudson.node_monitors.*
def j = Jenkins.get()
def old = j.getNode('$NODE')
if (old != null && '$force' != 'force') { println 'node exists, kept'; return }
if (old != null) { j.removeNode(old) }
def l = new JNLPLauncher(true)
l.setWebSocket(true)
def n = new DumbSlave('$NODE', '$REMOTE_FS', l)
n.setNodeDescription('build-01: permanent Linux build box (Docker container pg-static-01, outside the cluster)')
n.setNumExecutors($EXECUTORS)
n.setLabelString('$LABELS')
n.setMode(Node.Mode.EXCLUSIVE)
n.setRetentionStrategy(new RetentionStrategy.Always())
n.setNodeProperties([new DiskSpaceMonitorNodeProperty('16MiB', '64MiB', '32MiB', '128MiB')])
j.addNode(n)
println 'node created'" | tail -1
}

node_secret() {   # prints the node's secret; callers keep it out of logs
  jenkins_groovy "print jenkins.model.Jenkins.get().getComputer('$NODE')?.getJnlpMac() ?: ''"
}

node_json() { jenkins_get "/computer/$NODE/api/json?tree=offline,temporarilyOffline,offlineCauseReason,numExecutors,idle,displayName" 2>/dev/null || true; }
node_online() { [[ "$(jq -r '.offline' <<<"$(node_json)" 2>/dev/null)" == false ]]; }
# Connected is not the same as online: a connected node can still be flagged
# "temporarily offline" (someone clicked Mark this node temporarily offline).
node_connected() { [[ "$(jenkins_groovy "print jenkins.model.Jenkins.get().getComputer('$NODE')?.getChannel() != null" 2>/dev/null)" == true ]]; }

# --- the container ------------------------------------------------------------------
write_env() {
  local secret=$1
  mkdir -p "$SDIR"; chmod 700 "$SDIR"
  ( umask 077
    { echo "JENKINS_URL=$AGENT_JENKINS_URL"
      echo "JENKINS_AGENT_NAME=$NODE"
      echo "JENKINS_SECRET=$secret"
      echo "JENKINS_WEB_SOCKET=true"
      echo "JAVA_OPTS=-Xmx192m -XX:+UseSerialGC"
    } > "$ENVF.new" )
  mv "$ENVF.new" "$ENVF"; chmod 600 "$ENVF"
}

run_container() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER" --hostname build-01 --network kind \
    --restart unless-stopped --memory "$MEM" --memory-swap "$MEM" --cpus 1 \
    --tmpfs "$REMOTE_FS:rw,size=$WS_SIZE,mode=0755,uid=1000,gid=1000" \
    --label platform-lab.playground=static-agent \
    --env-file "$ENVF" "$AGENT_IMAGE" >/dev/null
}

container_state() { local s; s=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null) || s=absent; echo "$s"; }

wait_online() {   # wait until the agent is CONNECTED (returns 0), whatever flags the node carries
  local limit=${1:-120} t0; t0=$(date +%s)
  printf "  waiting for %s to connect" "$NODE"
  while (( $(date +%s) - t0 < limit )); do
    if node_connected; then echo; return 0; fi
    printf "."; sleep 3
  done
  echo; return 1
}

cmd_up() {
  preflight
  c_hdr "static agent: $NODE ($AGENT_IMAGE)"
  local mem_gb; mem_gb=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
  (( mem_gb >= 3 )) || c_warn "Docker has ${mem_gb} GB: the agent needs ${MEM} on top of kind"
  register_node | sed 's/^/  /'
  local secret; secret=$(node_secret)
  [[ -n $secret ]] || die "could not read the node secret from Jenkins"
  # (Re)create the container when it is missing, or when the secret IT HOLDS (not
  # the state file's) is not the controller's: a rebuilt controller, or a box
  # re-provisioned from an old file, has a stale one and loops on "Handshake error".
  local have=""
  [[ $(container_state) != absent ]] && have=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" | grep '^JENKINS_SECRET=' | cut -d= -f2-)
  if [[ $(container_state) == running && $have == "$secret" ]]; then
    c_ok "container $CONTAINER already running"
  else
    write_env "$secret"
    run_container
    c_ok "container $CONTAINER started"
  fi
  unset secret have
  if wait_online 120; then
    if node_online; then c_ok "$NODE is online: labels '$LABELS', $EXECUTORS executor, workspace $REMOTE_FS (tmpfs $WS_SIZE)"
    else c_warn "$NODE is CONNECTED but Jenkins keeps it offline: $(jq -r '.offlineCauseReason // "no reason recorded"' <<<"$(node_json)" | head -c 160)"; fi
  else c_warn "$NODE is not online yet: docker logs $CONTAINER, and $JENKINS_URL/computer/$NODE/"; fi
}

cmd_reset() {
  preflight
  c_hdr "static agent: back to baseline"
  register_node force | sed 's/^/  /'
  local secret; secret=$(node_secret)
  [[ -n $secret ]] || die "could not read the node secret from Jenkins"
  write_env "$secret"; unset secret
  run_container
  wait_online 120 && c_ok "$NODE online, empty workspace" || { c_bad "$NODE did not come online (docker logs $CONTAINER)"; return 1; }
}

# What a reboot or a re-provisioning does: start the container again from the
# state file as it is, without asking Jenkins for anything.
cmd_recreate() {
  [[ -f $ENVF ]] || die "no $ENVF: run up first"
  run_container
  c_ok "container $CONTAINER re-created from $ENVF"
}

cmd_status() {
  load_creds
  c_hdr "static agent"
  local cs; cs=$(container_state)
  [[ $cs == running ]] && c_ok "container $CONTAINER: running" || c_bad "container $CONTAINER: $cs"
  if jenkins_get /api/json >/dev/null 2>&1; then
    local nj; nj=$(node_json)
    if [[ -z $nj ]]; then c_bad "node $NODE is not registered in Jenkins"
    elif [[ "$(jq -r .offline <<<"$nj")" == false ]]; then
      c_ok "node $NODE: online, $(jq -r .numExecutors <<<"$nj") executor(s), $([[ "$(jq -r .idle <<<"$nj")" == true ]] && echo idle || echo busy)"
    else c_bad "node $NODE: OFFLINE ($(jq -r '.offlineCauseReason // "no reason recorded"' <<<"$nj" | head -c 200))"; fi
  else c_bad "Jenkins not answering on $JENKINS_URL"; fi
  if [[ $cs == running ]]; then
    echo "  workspace disk:  $(docker exec "$CONTAINER" df -h "$REMOTE_FS" | awk 'NR==2{print $3" used of "$2" ("$5")"}')"
    echo "  last agent log:  $(docker logs --tail 1 "$CONTAINER" 2>&1 | head -c 160)"
  fi
}

cmd_down() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 && c_ok "container $CONTAINER removed" || c_dim "  no container"
  if [[ -f "$STATE/creds.env" ]] && { load_creds; jenkins_get /api/json >/dev/null 2>&1; }; then
    jenkins_groovy "def j = jenkins.model.Jenkins.get(); def n = j.getNode('$NODE'); if (n) { j.removeNode(n); println 'node removed' } else { println 'no node' }" \
      | sed 's/^/  /'
  fi
  rm -rf "$SDIR"
  c_ok "static agent is down (image kept: docker rmi ${AGENT_IMAGE%@*} to reclaim ~500 MB)"
}

case "${1:-}" in
  up) cmd_up ;;
  status) cmd_status ;;
  reset) cmd_reset ;;
  recreate) cmd_recreate ;;
  down) cmd_down ;;
  -h|--help|help) usage 0 ;;
  *) usage 1 ;;
esac
