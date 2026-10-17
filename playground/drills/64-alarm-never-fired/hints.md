Start from the data, not the alarm. The Errors spike is real: query it
(`aws cloudwatch get-metric-statistics`, period 60, Sum, start-time ~24h ago,
the dimension the APP publishes). Then ask the same question the alarm asks.
What does `aws cloudwatch describe-alarms --alarm-names ...` say it is watching?
A CloudWatch metric is identified by namespace + name + the EXACT dimension set.
---
Put the two side by side: `aws cloudwatch list-metrics --namespace platform-lab/drill64`
(what exists) against the alarm's Namespace / MetricName / Dimensions (what it
watches). Compare every character of dimension Name and Value, including case.
Then read TreatMissingData: an alarm watching a metric that never has data is
not "OK", it is blind -- which setting made it look calm? And
`aws cloudwatch describe-alarm-history --alarm-name ...`: has it ever left OK?
---
There is no in-place edit of an alarm: `aws cloudwatch put-metric-alarm` with the
SAME alarm name and the full corrected definition replaces it (keep the name:
runbooks and routing hang off it). Fix the dimensions to what list-metrics shows.
Do not lower the threshold or flip the comparison to make it "fire": it must
fire at 5+ errors and stay quiet at 0. Decide TreatMissingData on purpose and be
ready to explain it. Prove the fix: publish a breaching datapoint
(`aws cloudwatch put-metric-data --namespace platform-lab/drill64 --metric-name
Errors --dimensions Service=checkout --value 20`) and watch the alarm reach ALARM
(a minute or two); `set-alarm-state` proves nothing.
