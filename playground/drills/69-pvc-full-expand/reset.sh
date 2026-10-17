#!/usr/bin/env bash
# Back to baseline: namespace platform-lab-drill69 gone and the EBS volume that
# belonged to it deleted (the PV reclaim policy is Delete, so the CSI driver does
# it; a lingering 'available' volume is deleted by the recorded ID). Acts ONLY
# when break.sh left $STATE/drill69.env. Skipped silently when the AWS tier is not up.
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"
aws_tier_up || exit 0
aws_env
ENVF="$STATE/drill69.env"
[[ -f $ENVF ]] || exit 0
source "$ENVF"
NS=platform-lab-drill69

K -n $NS delete sts audit-writer --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1
K -n $NS delete pvc --all --ignore-not-found --wait=false >/dev/null 2>&1
K delete ns $NS --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1

if [[ -n ${VOL:-} ]]; then
  for _ in $(seq 1 30); do
    st=$(aws ec2 describe-volumes --volume-ids "$VOL" --query 'Volumes[0].State' --output text 2>/dev/null) || break   # NotFound: gone
    [[ $st == available ]] && { aws ec2 delete-volume --volume-id "$VOL" >/dev/null 2>&1; }
    sleep 3
  done
fi
rm -f "$ENVF"
exit 0
