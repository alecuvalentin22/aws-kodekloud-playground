#!/usr/bin/env bash
# Fixed means:
#   1. ledger-db-0 is Running and Ready,
#   2. the data marker written at break time is read back from the RUNNING pod
#      (a Ready pod on a re-created, empty volume is the classic wrong fix: FAIL),
#   3. no capacity is left unschedulable without reason (PENALTY 20).
# Info line when the data now lives on another volume / in another AZ (fix B).
# API calls: kube get/exec/events (read), ec2 DescribeVolumes (read).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
NS=ledger
ENVF="$STATE/drill17.env"
[[ -f $ENVF ]] || { c_bad "no $ENVF: the drill was not started here"; exit 1; }
# shellcheck disable=SC1090
source "$ENVF"

if ! K -n $NS get sts ledger-db >/dev/null 2>&1; then c_bad "the StatefulSet ledger-db is gone from namespace $NS"; exit 1; fi
phase=$(K -n $NS get pod ledger-db-0 -o jsonpath='{.status.phase}' 2>/dev/null)
ready=$(K -n $NS get pod ledger-db-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [[ $phase != Running || $ready != True ]]; then
  why=$(K -n $NS get events --field-selector reason=FailedScheduling -o json 2>/dev/null | jq -r '[.items[].message]|last // empty')
  c_bad "ledger-db-0 is ${phase:-missing}, not Running and Ready${why:+: $why}"
  exit 1
fi
c_ok "ledger-db-0 is Running and Ready on $(K -n $NS get pod ledger-db-0 -o jsonpath='{.spec.nodeName}')"

pv=$(K -n $NS get pvc data-ledger-db-0 -o jsonpath='{.spec.volumeName}' 2>/dev/null)
vol=$(K get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)
uid=$(K -n $NS get pvc data-ledger-db-0 -o jsonpath='{.metadata.uid}' 2>/dev/null)

got=$(K -n $NS exec ledger-db-0 -- psql -U postgres -tAc "select v from marker limit 1" 2>/dev/null | tr -d '[:space:]')
rows=$(K -n $NS exec ledger-db-0 -- psql -U postgres -tAc "select count(*) from entries" 2>/dev/null | tr -d '[:space:]')
if [[ $got == "$MARKER" ]]; then
  c_ok "the ledger data is intact (marker found, ${rows:-?} entries)"
else
  c_bad "the pod is up but the ledger data is NOT there (marker ${got:-missing}). The volume was re-created empty: PVC uid $PVC_UID -> $uid, volume $VOL -> ${vol:-?}. The original data is gone; month-end close cannot run on this."
  exit 1
fi

if [[ -n $vol && $vol != "$VOL" ]]; then
  vaz=$(aws ec2 describe-volumes --volume-ids "$vol" --query 'Volumes[0].AvailabilityZone' --output text 2>/dev/null)
  c_dim "  info: the data moved volumes ($VOL in $VAZ -> $vol in ${vaz:-?}): the snapshot-and-restore fix"
fi

# Cordoned nodes. The node(s) the drill 'lost' may stay cordoned only if the data
# left that AZ (they stand for a node that no longer exists); otherwise capacity
# is being left unschedulable for no reason.
bad=""
for n in $(K get nodes -o json | jq -r '.items[]|select(.spec.unschedulable==true)|.metadata.name'); do
  if grep -qw "$n" <<<"$ZONE_NODES" && [[ -n $vol && $vol != "$VOL" ]]; then continue; fi
  bad="$bad $n"
done
if [[ -n $bad ]]; then
  echo "PENALTY 20 node(s) still cordoned:$bad. Capacity left unschedulable."
  c_warn "node(s) still cordoned:$bad"
fi
exit 0
