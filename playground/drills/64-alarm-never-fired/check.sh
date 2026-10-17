#!/usr/bin/env bash
# Fixed means the alarm really fires on the real metric, not that it "looks right":
#   1. the alarm exists and watches namespace + metric + the EXACT dimension set the
#      app publishes (recorded by break.sh; list-metrics shows the same),
#   2. THIS script then publishes breaching datapoints (Errors=20, three of them over
#      ~1 min) to the real metric and waits, bounded at 4 min, for the alarm to reach
#      ALARM *because of those datapoints* (StateReasonData), then publishes a 0.
# set-alarm-state, a missing-data=breaching alarm that fires on silence, or a
# metric the solver invented all fail step 2.
# PENALTY 30: the alarm only "works" because it would also page on zero errors
# (threshold lowered to 0 / comparison flipped), or was recreated under another name.
# API calls: cloudwatch DescribeAlarms, PutMetricData. (SetAlarmState is denied on KodeKloud accounts.)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
for t in jq aws; do command -v "$t" >/dev/null || die "$t not on PATH"; done
REC="$STATE/drill64.env"
[[ -f $REC ]] || { c_bad "drill 64 is not running (no $REC)"; exit 1; }
# shellcheck disable=SC1090
source "$REC"

get_alarm() { aws cloudwatch describe-alarms --alarm-names "$1" --query 'MetricAlarms[0]' --output json 2>/dev/null; }
A=$(get_alarm "$D64_ALARM"); NAME=$D64_ALARM; pen_rename=0
if [[ -z $A || $A == null ]]; then
  others=$(aws cloudwatch describe-alarms --alarm-name-prefix platform-lab-drill64 --query 'MetricAlarms[].AlarmName' --output text 2>/dev/null)
  if [[ $(wc -w <<<"$others") -eq 1 ]]; then
    NAME=$others; A=$(get_alarm "$NAME"); pen_rename=1
    c_warn "$D64_ALARM no longer exists; judging $NAME instead"
  else
    c_bad "alarm $D64_ALARM is gone and no replacement exists. On-call routing hangs off that name: fix it, do not delete it."; exit 1
  fi
fi

# --- 1. what does the alarm watch? -------------------------------------------
j() { jq -r "$1" <<<"$A"; }
metric=$(j '.MetricName // empty'); ns=$(j '.Namespace // empty')
dims=$(j '[.Dimensions[]? | "\(.Name)=\(.Value)"] | sort | join(",")')
want="$D64_DIM_NAME=$D64_DIM_VALUE"
if [[ -z $metric ]]; then c_bad "alarm $NAME is a metric-math alarm; this drill expects a plain single-metric alarm"; exit 1; fi
echo "  the app publishes:  $D64_NS / $D64_METRIC / $want"
echo "  the alarm watches:  $ns / $metric / ${dims:-<no dimensions>}"
if [[ $ns != "$D64_NS" || $metric != "$D64_METRIC" || $dims != "$want" ]]; then
  c_bad "the alarm watches a metric that never receives a datapoint: namespace + name + exact dimensions identify a metric (compare with list-metrics)"
  exit 1
fi
c_ok "the alarm watches an existing metric (dimensions match list-metrics)"

period=$(j '.Period'); evalp=$(j '.EvaluationPeriods'); dta=$(j '.DatapointsToAlarm // .EvaluationPeriods')
thr=$(j '.Threshold'); cmp=$(j '.ComparisonOperator'); tmd=$(j '.TreatMissingData // "missing"')
stat=$(j '.Statistic // .ExtendedStatistic // "?"')
echo "  definition: $stat $cmp $thr, ${dta}/${evalp} x ${period}s, TreatMissingData=$tmd"
# Would a minute with 0 errors breach? Then it pages for nothing.
zero=$(jq -n --arg c "$cmp" --argjson t "$thr" '
  if $c=="GreaterThanThreshold" then 0>$t elif $c=="GreaterThanOrEqualToThreshold" then 0>=$t
  elif $c=="LessThanThreshold" then 0<$t elif $c=="LessThanOrEqualToThreshold" then 0<=$t else false end')
if [[ $zero == true ]]; then
  c_warn "a minute with 0 errors would breach this alarm: it fires, but it also pages for nothing"
  echo "PENALTY 30 The alarm breaches at zero errors (threshold lowered or comparison flipped). It 'fires' only because it always fires: fix the dimensions, keep a threshold that means something."
fi
if (( pen_rename )); then
  echo "PENALTY 30 The alarm was deleted and recreated as $NAME. Paging, dashboards and runbooks reference $D64_ALARM; put-metric-alarm with the same name replaces it in place."
fi
if [[ $tmd == breaching ]]; then
  c_warn "TreatMissingData=breaching: right only if checkout publishes Errors every minute (zeros included); on a sparse metric it sits in ALARM whenever there are no errors"
fi

# --- 2. does it fire? ------------------------------------------------------------
pub() {   # pub <value>
  aws cloudwatch put-metric-data --namespace "$D64_NS" --metric-name "$D64_METRIC" \
    --dimensions "$D64_DIM_NAME=$D64_DIM_VALUE" --value "$1" --unit Count >/dev/null 2>&1
}
state() { aws cloudwatch describe-alarms --alarm-names "$NAME" --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null; }
# An alarm already in ALARM (a wrong fix that fires on silence, an earlier check)
# proves nothing and does not change state again when real errors arrive. Publish
# zeros until it settles (<= 100 s): real data below the threshold must calm it.
if [[ $(state) == ALARM ]]; then
  echo "  the alarm is in ALARM before any error is published; publishing Errors=0 until it settles..."
  c0=$(date +%s); z=0
  while (( $(date +%s) - c0 < 100 )); do
    (( z < 2 )) && { pub 0; z=$((z+1)); }
    [[ $(state) != ALARM ]] && break
    sleep 10
  done
  if [[ $(state) == ALARM ]]; then
    c_bad "still in ALARM 100 s after zero-error datapoints: an alarm that cannot go back to OK pages for nothing"
    exit 1
  fi
  sleep 60   # let the zero datapoints age out of the evaluation window
fi
START=$(date +%s)
limit=240; t0=$START; pubs=0; fired=0
echo "  publishing Errors=20 to the real metric and waiting up to ${limit}s for ALARM..."
while (( $(date +%s) - t0 < limit )); do
  if (( pubs < 3 && $(date +%s) - t0 >= pubs * 30 )); then pub 20; pubs=$((pubs+1)); fi
  B=$(get_alarm "$NAME")
  if [[ $(jq -r '.StateValue' <<<"$B") == ALARM ]]; then
    ts=$(jq -r '.StateUpdatedTimestamp' <<<"$B")
    ok=$(jq -n --argjson b "$B" --argjson thr "$thr" '
      ($b.StateReasonData // "{}" | try fromjson catch {}) as $d
      | (([$d.recentDatapoints[]?] | map(numbers) | map(select(. >= $thr)) | length) > 0)')
    upd=$(python3 -c 'import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))' "$ts" 2>/dev/null || echo 0)
    if [[ $ok == true ]] && (( upd >= START - 5 )); then fired=1; break; fi
  fi
  sleep 15
done
pub 0
if (( ! fired )); then
  B=$(get_alarm "$NAME")
  c_bad "no ALARM from real datapoints within ${limit}s (state $(jq -r .StateValue <<<"$B"): $(jq -r '.StateReason' <<<"$B" | cut -c1-160))"
  echo "  Errors=20 was published three times; with ${dta}/${evalp} x ${period}s the alarm should have fired. Look at its statistic, period, threshold and comparison."
  exit 1
fi
c_ok "published Errors=20: the alarm went to ALARM on those datapoints"
exit 0
