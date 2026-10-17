#!/usr/bin/env bash
# Fixed means:
#   1. audit-writer-0 is Running and Ready and its container has been up >= 30 s
#      (a pod that restarts every few minutes is not fixed),
#   2. it is still the SAME claim, PV and EBS volume as at break time (the
#      candidate that deleted the PVC got a new, empty volume: FAIL),
#   3. the PVC capacity is >= 2 Gi (real resize done, not only requested) and
#      the filesystem seen by the pod is >= ~1.9 G (df): the FileSystemResizePending
#      step is finished,
#   4. the marker file written at break time is read back from the running pod
#      (marker gone: FAIL),
#   5. the writer is appending again (audit.log modified in the last 20 s).
# PENALTY 20 when the claim asks for more than 10 Gi (cost, and 30 GB per volume
# is the lab limit). PENALTY 15 when audit.log has fewer lines than at break time
# (the audit trail was truncated or deleted to make room). Deleting the spool
# backlog is allowed -- but only the expansion makes the check pass.
# API calls: kube get/exec (read). No ec2 calls.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
NS=platform-lab-drill69
ENVF="$STATE/drill69.env"
[[ -f $ENVF ]] || { c_bad "no $ENVF: the drill was not started here"; exit 1; }
# shellcheck disable=SC1090
source "$ENVF"

# bytes of a Kubernetes quantity (Ki Mi Gi Ti, k M G T, or plain)
qbytes() {
  local q=$1 n u
  n=${q%%[A-Za-z]*}; u=${q#"$n"}
  case $u in
    Ki) echo $(( n * 1024 )) ;; Mi) echo $(( n * 1048576 )) ;; Gi) echo $(( n * 1073741824 )) ;;
    Ti) echo $(( n * 1099511627776 )) ;; k) echo $(( n * 1000 )) ;; M) echo $(( n * 1000000 )) ;;
    G) echo $(( n * 1000000000 )) ;; T) echo $(( n * 1000000000000 )) ;; *) echo "${n:-0}" ;;
  esac
}
GI=1073741824

K -n $NS get sts audit-writer >/dev/null 2>&1 || { c_bad "the StatefulSet audit-writer is gone from namespace $NS"; exit 1; }
K -n $NS get pvc data-audit-writer-0 >/dev/null 2>&1 || { c_bad "the claim data-audit-writer-0 is gone"; exit 1; }

# --- 1. running, ready, stable for 30 s ------------------------------------------
podstate() { K -n $NS get pod audit-writer-0 -o json 2>/dev/null \
  | jq -r '[.status.phase, ((.status.conditions // [])|map(select(.type=="Ready"))|.[0].status // "False"),
            (.status.containerStatuses[0].state.running.startedAt // "-"), (.status.containerStatuses[0].restartCount // 0),
            (.status.containerStatuses[0].state.waiting.reason // "-")]|@tsv'; }
IFS=$'\t' read -r phase ready started restarts waiting < <(podstate)
if [[ $phase != Running || $ready != True ]]; then
  why=$(K -n $NS logs audit-writer-0 --previous --tail=2 2>&1 | tail -n 2 | tr '\n' ' ')
  [[ $waiting == - ]] && waiting=""
  c_bad "audit-writer-0 is ${waiting:-${phase:-missing}} (Ready=$ready, restarts $restarts)${why:+. last log lines: $why}"
  exit 1
fi
age=$(( $(date +%s) - $(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$started" +%s 2>/dev/null || date -u -d "$started" +%s) ))
if (( age < 30 )); then
  sleep $(( 31 - age ))
  IFS=$'\t' read -r phase ready started2 restarts _ < <(podstate)
  if [[ $phase != Running || $ready != True || $started2 != "$started" ]]; then
    c_bad "audit-writer-0 restarted again within 30 s of starting (restarts $restarts): not stable"; exit 1
  fi
fi
c_ok "audit-writer-0 is Running and Ready, stable for 30 s (restarts so far: $restarts)"

# --- 2. same volume --------------------------------------------------------------
uid=$(K -n $NS get pvc data-audit-writer-0 -o jsonpath='{.metadata.uid}')
pv=$(K -n $NS get pvc data-audit-writer-0 -o jsonpath='{.spec.volumeName}')
vol=$(K get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)
if [[ $uid != "$PVC_UID" || $vol != "$VOL" ]]; then
  c_bad "the volume was replaced (claim uid $PVC_UID -> $uid, volume $VOL -> ${vol:-?}): the audit trail on the original volume is gone. Deleting a PVC deletes the EBS volume (reclaim policy Delete)."
  exit 1
fi
c_ok "same claim and same EBS volume as at the start ($VOL)"

# --- 3. really resized: PVC capacity and the filesystem the pod sees ---------------
req=$(K -n $NS get pvc data-audit-writer-0 -o jsonpath='{.spec.resources.requests.storage}')
cap=$(K -n $NS get pvc data-audit-writer-0 -o jsonpath='{.status.capacity.storage}')
conds=$(K -n $NS get pvc data-audit-writer-0 -o json | jq -r '[.status.conditions[]?.type]|join(",")')
if (( $(qbytes "${cap:-0}") < 2 * GI )); then
  if (( $(qbytes "$req") >= 2 * GI )); then
    c_bad "the claim asks for $req but its capacity is still ${cap:-?} (conditions: ${conds:-none}): the resize is not finished yet, look at kubectl describe pvc"
  else
    c_bad "the claim is still ${cap:-?}: the writer needs more room than 1 Gi gives it (kubectl get sc: ALLOWVOLUMEEXPANSION)"
  fi
  exit 1
fi
c_ok "PVC capacity is $cap (requested $req)"
kb=$(K -n $NS exec audit-writer-0 -- df -P -k /data 2>/dev/null | awk 'NR==2{print $2}')
if [[ -z $kb ]] || (( kb < 1992294 )); then
  c_bad "the pod's /data filesystem is still $(( ${kb:-0} / 1024 )) MiB: the volume grew on the AWS side but the filesystem has not (FileSystemResizePending: it is grown on the node while the volume is mounted)"
  exit 1
fi
c_ok "/data inside the pod is $(( kb / 1024 )) MiB"

# --- 4. the data -----------------------------------------------------------------
got=$(K -n $NS exec audit-writer-0 -- cat /data/audit-anchor.txt 2>/dev/null | tr -d '[:space:]')
if [[ $got != "$MARKER" ]]; then
  c_bad "the audit history is NOT there (marker file ${got:-missing}). The data was deleted or the volume re-created; the audit trail cannot be regenerated."
  exit 1
fi
lines=$(K -n $NS exec audit-writer-0 -- sh -c 'wc -l < /data/audit.log' 2>/dev/null | tr -d '[:space:]')
c_ok "the marker file is intact (audit.log has ${lines:-?} lines, ${LINES} at the start)"

# --- 5. writing again ------------------------------------------------------------
fresh=$(K -n $NS exec audit-writer-0 -- sh -c 'echo $(( $(date +%s) - $(stat -c %Y /data/audit.log) ))' 2>/dev/null | tr -d '[:space:]')
if [[ -z $fresh ]] || (( fresh > 20 )); then c_bad "audit.log is not being written to (last write ${fresh:-?} s ago)"; exit 1; fi
c_ok "audit.log is growing again (last append ${fresh}s ago)"

if (( $(qbytes "$req") > 10 * GI )); then
  echo "PENALTY 20 The claim asks for $req. Size for the need plus headroom (2-5 Gi here); EBS modifications are limited to about one per 6 hours per volume, and this lab allows 30 GB per volume."
  c_warn "PVC request $req is far more than this workload needs"
fi
if [[ -n $lines ]] && (( lines < LINES )); then
  echo "PENALTY 15 audit.log lost lines (${lines} < ${LINES} at the start): audit history was truncated or deleted to make room. Expanding is the fix; deleting evidence is not."
  c_warn "audit.log has fewer lines than at the start"
fi
exit 0
