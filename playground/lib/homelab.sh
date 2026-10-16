# shellcheck shell=bash
# The homelab tier: drills against the RKE2 cluster on the home-lab PC.
# Source AFTER lib/common.sh.
#
#   kubectl   the LAN kubeconfig (https://192.168.1.153:6443, no tunnel)
#   VM ops    `hl_wsl <cmd>` runs a command in WSL (where Incus lives)
#   answers   ~/platform-playground-homelab/answers/<id>.md  (what checks read)
#
# Own state dir, so the local tier's scores/creds are untouched.

HL_LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export KUBECONFIG="${HOMELAB_KUBECONFIG:-$HL_LAB/homelab/generated/rke2-lan.kubeconfig}"
HL_WSL="${HOMELAB_SSH:-homelab-1}-wsl"
HL_IP="${HOMELAB_IP:-192.168.1.153}"
HL_STATE="${PLAYGROUND_STATE:-$HOME/.local/state/platform-lab-playground}/homelab"
HL_WORK="${HOMELAB_WORK:-$HOME/platform-playground-homelab}"
HL_ANSWERS="$HL_WORK/answers"
mkdir -p "$HL_STATE" "$HL_ANSWERS"

K() { kubectl "$@"; }
hl_wsl() { ssh -n -o BatchMode=yes -o ConnectTimeout=8 "$HL_WSL" "$@"; }

# Wait until a condition command succeeds, or give up after N seconds.
hl_wait() {  # hl_wait <seconds> <description> <command...>
  local limit=$1 what=$2; shift 2
  local t0; t0=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    (( $(date +%s) - t0 > limit )) && { c_bad "timed out after ${limit}s waiting for: $what"; return 1; }
    sleep 5
  done
}

hl_nodes_ready() { [[ $(K get nodes --no-headers 2>/dev/null | grep -c ' Ready') -eq 3 ]]; }

# The workload most drills watch: demo-api in demo-ci, deployed by the platform
# Jenkins (http://jenkins.<ip>.nip.io). Ready replicas == desired?
hl_demo_ready() {
  local want got
  want=$(K -n demo-ci get deploy demo-api -o jsonpath='{.spec.replicas}' 2>/dev/null)
  got=$(K -n demo-ci get deploy demo-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [[ -n $want && "${got:-0}" -eq "$want" ]]
}

# The answer file a drill asks for, lower-cased, or empty.
hl_answer() { tr '[:upper:]' '[:lower:]' < "$HL_ANSWERS/$1.md" 2>/dev/null || true; }
