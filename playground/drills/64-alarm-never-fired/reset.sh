#!/usr/bin/env bash
# Removes what drill 64 created, and ONLY when break.sh recorded it in
# $STATE/drill64.env (absent = nothing to do, so a parallel `play reset` or another
# drill is never touched).
#  * alarms: deletes the recorded alarm plus any other alarm under the
#    platform-lab-drill64 prefix. KodeKloud playground accounts DENY
#    cloudwatch:DeleteAlarms (measured 2026-10-17), so when the delete is refused
#    the recorded alarm is overwritten in place with a correct, inert definition
#    (no actions, "retired" description) and break.sh simply re-puts it next time:
#    one alarm with a fixed name is the most this drill ever leaves in the account.
#    Extra alarms with other names cannot be removed there; their actions are disabled.
#  * metric data cannot be deleted at all: CloudWatch keeps it until it expires
#    (1-minute data after 15 days).
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"
REC="$STATE/drill64.env"
[[ -f $REC ]] || exit 0
[[ -r "$AWS_CREDS_FILE" ]] || exit 0
aws_env
aws sts get-caller-identity >/dev/null 2>&1 || exit 0     # creds gone: leave the record for next time
# shellcheck disable=SC1090
source "$REC"
names=$(aws cloudwatch describe-alarms --alarm-name-prefix platform-lab-drill64 --query 'MetricAlarms[].AlarmName' --output text 2>/dev/null)
for n in ${D64_ALARM:-} $names; do echo "$n"; done | sort -u | while read -r n; do
  [[ -n $n ]] || continue
  if ! aws cloudwatch delete-alarms --alarm-names "$n" >/dev/null 2>&1; then
    if [[ $n == "${D64_ALARM:-}" ]]; then
      aws cloudwatch put-metric-alarm --alarm-name "$n" \
        --alarm-description "retired drill-64 alarm (cloudwatch:DeleteAlarms is denied on this account; safe to ignore)" \
        --namespace "$D64_NS" --metric-name "$D64_METRIC" --dimensions "Name=$D64_DIM_NAME,Value=$D64_DIM_VALUE" \
        --statistic Sum --period 60 --evaluation-periods 1 --datapoints-to-alarm 1 \
        --threshold 5 --comparison-operator GreaterThanOrEqualToThreshold \
        --treat-missing-data notBreaching >/dev/null 2>&1
    else
      aws cloudwatch disable-alarm-actions --alarm-names "$n" >/dev/null 2>&1
    fi
  fi
done
rm -f "$REC"
exit 0
