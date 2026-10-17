#!/usr/bin/env bash
# "The outage" is REAL data in a REAL CloudWatch custom metric
# (platform-lab/drill64 Errors, Service=checkout, 20 minutes of 14..30 errors/min,
# ending ~100 minutes before the drill starts) and the alarm on it is REAL -- a teammate's alarm that
# watches dimension service=checkout (lower-case name) when the app publishes
# Service=checkout. Different dimensions are a different metric, so the alarm
# never sees a datapoint; TreatMissingData=notBreaching turns that blindness into
# a calm "OK". Metric data cannot be deleted (it expires after 15 days), so a
# repeat run just re-publishes the same datapoints.
#
# AWS API calls: cloudwatch PutMetricData, PutMetricAlarm (+TagResource, denied here: skipped),
# DescribeAlarms, DescribeAlarmHistory. Names: prefix platform-lab-drill64.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
for t in jq aws; do command -v "$t" >/dev/null || die "$t not on PATH"; done

NS=platform-lab/drill64 METRIC=Errors DIM_NAME=Service DIM_VALUE=checkout
ALARM=platform-lab-drill64-checkout-errors
mkdir -p "$STATE"
bash "$HERE/reset.sh" >/dev/null 2>&1 || true     # clears an earlier run (acts only on what drill64.env recorded)
rm -f "$STATE/drill64.env"

# The outage ran for 20 minutes, ending ~100 minutes ago. CloudWatch only keeps
# datapoints that are at most ~3 hours old when they are published (older ones are
# silently dropped -- measured on this account), so "last night" cannot be real data.
now=$(date +%s); t0=$(( now / 60 * 60 - 120 * 60 ))
day=$(date -u -r "$t0" +%FT%TZ)

# 10 min of normal (1 error), 20 min outage (14..30), 10 min of recovery.
jq -n --argjson t0 "$t0" --arg ns "$NS" --arg dn "$DIM_NAME" --arg dv "$DIM_VALUE" '
  [ range(-10; 30) | . as $m
    | { MetricName: "Errors", Unit: "Count",
        Dimensions: [{Name: $dn, Value: $dv}],
        Timestamp: (($t0 + $m * 60) | todate),
        Value: (if $m < 0 or $m >= 20 then 1 else 14 + (($m % 5) * 4) end) } ]' > "$STATE/drill64.data.json"
aws cloudwatch put-metric-data --namespace "$NS" --metric-data "file://$STATE/drill64.data.json"
rm -f "$STATE/drill64.data.json"
echo "published the outage: from $day for 20 min, Errors 14..30 per minute, $NS $DIM_NAME=$DIM_VALUE"

# Tom's alarm: lower-case "service" is a different dimension from "Service".
aws cloudwatch put-metric-alarm --alarm-name "$ALARM" \
  --alarm-description "checkout 5xx: page when >= 5 errors in a minute (copied from the Datadog monitor)" \
  --namespace "$NS" --metric-name "$METRIC" --dimensions "Name=service,Value=$DIM_VALUE" \
  --statistic Sum --period 60 --evaluation-periods 1 --datapoints-to-alarm 1 \
  --threshold 5 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching
aws cloudwatch tag-resource --resource-arn "arn:aws:cloudwatch:${AWS_REGION:-us-east-1}:$(aws_account):alarm:$ALARM" \
  --tags Key=platform-lab-drill,Value=64 2>/dev/null || echo "(alarm tagging not allowed here; skipped)"

cat > "$STATE/drill64.env" <<ENV
D64_ALARM=$ALARM
D64_NS=$NS
D64_METRIC=$METRIC
D64_DIM_NAME=$DIM_NAME
D64_DIM_VALUE=$DIM_VALUE
D64_OUTAGE_START=$day
ENV

# Show that the alarm sat through the outage: it should settle to OK on its own
# (no data + notBreaching) and never have been ALARM.
for _ in $(seq 1 14); do
  st=$(aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].StateValue' --output text)
  [[ $st == OK ]] && break
  sleep 10
done
echo "alarm state: $st"
aws cloudwatch describe-alarm-history --alarm-name "$ALARM" --history-item-type StateUpdate \
  --query 'AlarmHistoryItems[].HistorySummary' --output text
