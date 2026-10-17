#!/usr/bin/env bash
# Back to baseline: namespace ledger gone, every node schedulable, and the EBS
# volumes/snapshots this drill or its solver made deleted. Volumes are found by
# the tag break.sh sets (platform-lab-drill=17), by the CSI driver's own tag for
# a PVC in namespace ledger, by the recorded volume ID, and by being restored
# from a snapshot of that volume. Only volumes NOT attached to an instance are deleted.
# Skipped silently when the AWS tier is not up.
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"
aws_tier_up || exit 0
aws_env
ENVF="$STATE/drill17.env"
[[ -f $ENVF ]] && source "$ENVF"
NS=ledger

# 1. the workload (pod, then PVC; the CSI driver deletes the volume, reclaim=Delete)
K -n $NS delete sts ledger-db --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1
K -n $NS delete pvc --all --ignore-not-found --wait=false >/dev/null 2>&1
K delete ns $NS --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1
# a static PV the solver created (Retain) outlives the namespace
for pv in $(K get pv -o json 2>/dev/null | jq -r --arg v "${VOL:-none}" '.items[]|select(.spec.claimRef.namespace=="ledger" or .spec.csi.volumeHandle==$v)|.metadata.name'); do
  K patch pv "$pv" -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1
  K delete pv "$pv" --ignore-not-found --wait=false >/dev/null 2>&1
done

# 2. nodes
for n in $(K get nodes -o name); do
  K uncordon "$n" >/dev/null 2>&1
  K annotate "$n" platform-lab/drill17- >/dev/null 2>&1
done

# 3. snapshots of the drill's volume, then volumes
snaps=""
if [[ -n ${VOL:-} ]]; then
  snaps=$(aws ec2 describe-snapshots --owner-ids self --filters Name=volume-id,Values="$VOL" --query 'Snapshots[].SnapshotId' --output text 2>/dev/null)
fi
tagged=$(aws ec2 describe-snapshots --owner-ids self --filters Name=tag:platform-lab-drill,Values=17 --query 'Snapshots[].SnapshotId' --output text 2>/dev/null)
snaps="$snaps $tagged"
vols=""
add() { for x in "$@"; do [[ -n $x && $x != None ]] && vols="$vols $x"; done; }
add $(aws ec2 describe-volumes --filters Name=tag:platform-lab-drill,Values=17 --query 'Volumes[].VolumeId' --output text 2>/dev/null)
add $(aws ec2 describe-volumes --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=$NS --query 'Volumes[].VolumeId' --output text 2>/dev/null)
[[ -n ${VOL:-} ]] && add "$VOL"
for s in $snaps; do
  add $(aws ec2 describe-volumes --filters Name=snapshot-id,Values="$s" --query 'Volumes[].VolumeId' --output text 2>/dev/null)
done
for v in $(echo $vols | tr ' ' '\n' | sort -u); do
  st=$(aws ec2 describe-volumes --volume-ids "$v" --query 'Volumes[0].State' --output text 2>/dev/null) || continue
  for _ in $(seq 1 20); do [[ $st == available ]] && break; sleep 3
    st=$(aws ec2 describe-volumes --volume-ids "$v" --query 'Volumes[0].State' --output text 2>/dev/null) || break; done
  [[ $st == available ]] && aws ec2 delete-volume --volume-id "$v" >/dev/null 2>&1
done
for s in $(echo $snaps | tr ' ' '\n' | sort -u); do
  [[ -n $s && $s != None ]] && aws ec2 delete-snapshot --snapshot-id "$s" >/dev/null 2>&1
done
rm -f "$ENVF"
exit 0
