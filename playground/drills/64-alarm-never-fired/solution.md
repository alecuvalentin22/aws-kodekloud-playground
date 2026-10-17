ROOT CAUSE
  The alarm watches a metric that has never had a datapoint. A CloudWatch metric
  is identified by namespace + metric name + the EXACT dimension set; the app
  publishes platform-lab/drill64 Errors {Service=checkout}, the alarm watches
  {service=checkout}. Dimension names are case-sensitive, so those are two
  different metrics, and the alarm's one never receives anything:
    aws cloudwatch list-metrics --namespace platform-lab/drill64     # Service=checkout
    aws cloudwatch describe-alarms --alarm-names platform-lab-drill64-checkout-errors
                                                                      # service=checkout
    get-metric-statistics with Service  -> the 20-minute spike
    get-metric-statistics with service  -> []  (never any data)
  TreatMissingData=notBreaching then did the hiding: "no data" is evaluated as
  "not breaching", so the alarm flipped INSUFFICIENT_DATA -> OK in its first minute
  and stayed there through the outage. StateReason says it:
    "no datapoints were received for 1 period and 1 missing datapoint was
     treated as [NonBreaching]"
  describe-alarm-history shows one transition ever, and no ALARM. A green alarm
  that has never seen data is the dangerous kind: nothing distinguishes it from
  a healthy service.

FIX
  put-metric-alarm replaces an alarm in place when the name is the same, but it
  takes the WHOLE definition (there is no "change one field"):
    aws cloudwatch put-metric-alarm --alarm-name platform-lab-drill64-checkout-errors \
      --namespace platform-lab/drill64 --metric-name Errors \
      --dimensions Name=Service,Value=checkout \
      --statistic Sum --period 60 --evaluation-periods 1 \
      --threshold 5 --comparison-operator GreaterThanOrEqualToThreshold \
      --treat-missing-data notBreaching
  Keep the name (pager routing, dashboards and runbooks hang off it). Changing
  the definition resets the state to INSUFFICIENT_DATA until the next evaluation.
  Then PROVE it with real data, not set-alarm-state:
    aws cloudwatch put-metric-data --namespace platform-lab/drill64 \
      --metric-name Errors --dimensions Service=checkout --value 20
  and watch describe-alarms: ALARM within a minute or two, with the datapoint in
  StateReason. (The check does exactly this: three datapoints of 20 over a minute,
  waits up to four minutes, then publishes a 0.)

THE JUDGMENT CALLS (no penalty, but say them out loud)
  TreatMissingData. The four options, for an Errors count:
    notBreaching  no data = no errors. Right when the app only emits Errors on
                  failure, which is what Tom said. Keep it, but it makes silence
                  indistinguishable from health, which is how this went unnoticed.
    breaching     no data = problem. Right when the metric is emitted every
                  period (emit zeros). On a sparse metric it sits in ALARM
                  whenever there are no errors.
    ignore        keep the current state through gaps; nothing changes until a
                  datapoint arrives. Fits flapping sparse metrics.
    missing       the default: the alarm goes INSUFFICIENT_DATA after enough gaps.
  Best answer: make the app emit Errors=0 every minute and use breaching (or
  notBreaching plus a separate heartbeat alarm on a request-count metric), and
  alarm on INSUFFICIENT_DATA as its own signal. "Silence is OK" must be a
  decision, not an accident of copying a Datadog monitor.
  Period and evaluation. 60 s x 1 pages on one bad minute (noisy for a
  low-traffic service); 3 of 5 datapoints (DatapointsToAlarm) pages on a
  sustained problem and ignores a blip. Statistic Sum of errors suits a count;
  an error RATE (errors / requests) needs metric math, and is what Datadog's
  "error rate" monitor really was.
  Not fixes: set-alarm-state (a manual flip back in a minute, proves nothing; KodeKloud denies it anyway);
  a threshold or comparison that also breaches at 0 errors (pages for nothing:
  PENALTY 30; a bare GreaterThan 0, paging on any single error, is a judgment
  call and is not penalized); TreatMissingData=breaching alone (the alarm turns ALARM, but from
  silence, still watching the wrong metric; the check refuses it); deleting the
  alarm and creating another name (PENALTY 30: routing hangs off the name).

HOW THE DRILL WORKS
  break.sh publishes 40 real datapoints (Service=checkout; 20 minutes of 14..30
  errors/min, ending ~100 min before the drill starts) and creates the alarm with
  dimension service. The outage cannot be "last night": CloudWatch silently drops
  datapoints older than ~3 hours at publish time (measured on this account).
  Metric data cannot be deleted; it expires. KodeKloud accounts also deny
  cloudwatch:DeleteAlarms, so reset.sh overwrites the one fixed-name alarm with
  an inert definition instead of deleting it.

WHAT STOPS IT RECURRING
  Alarms as reviewed code (Terraform) next to the code that emits the metric,
  a shared constant for the dimension names, alarm on INSUFFICIENT_DATA /
  a heartbeat for "the pipeline itself is silent", and a game-day: publish a
  synthetic breaching datapoint after every alarm change (this check).

SAY THIS IN THE INTERVIEW
  "The alarm said OK, but OK from what? I compared the alarm's namespace, metric
  and dimensions against list-metrics: the app publishes Service, the alarm
  watched service. Different dimensions are a different metric, so it never saw
  a datapoint, and TreatMissingData=notBreaching turned that blindness into a
  green OK; the alarm history had never left it. I fixed the dimensions by
  re-putting the alarm under the same name so paging routes stay valid, and I
  proved it by publishing a real breaching datapoint and watching it go to
  ALARM, not by forcing the state. Then I made the missing-data choice on
  purpose: for a metric that only appears on errors notBreaching is right, so I
  added a heartbeat so that silence is itself alerting. It is the same in
  Datadog: a monitor on a tag that no host has is 'No Data', and 'notify on no
  data' is the setting that decides whether anyone finds out."
