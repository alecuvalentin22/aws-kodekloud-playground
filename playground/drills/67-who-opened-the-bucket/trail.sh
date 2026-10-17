# shellcheck shell=bash
# CloudTrail helpers shared by break.sh and check.sh of drill 67. Source after aws_env.
#
#   trail_culprits BUCKET SINCE_EPOCH MARKER
#       one JSON object per line for the culprit events: PutBucketPolicy and
#       PutBucketPublicAccessBlock on BUCKET, sent by a client whose userAgent contains
#       MARKER (the teammate's script). Fields: id, name, time (UTC ISO), arn, ua.
#
# AWS API calls: cloudtrail:LookupEvents (management events; read-only). The API is
# limited to 2 requests/second per account and shared with everyone in the account,
# so a throttled call is retried.
trail_culprits() {
  local bucket=$1 since=$2 marker=$3 out="" i
  for i in 1 2 3 4 5; do
    out=$(aws cloudtrail lookup-events --region us-east-1 \
            --lookup-attributes "AttributeKey=ResourceName,AttributeValue=$bucket" \
            --start-time "$since" --output json 2>&1) && break
    out=""; sleep $((i * 3))
  done
  [[ -n $out ]] || return 1
  jq -c --arg m "$marker" '
    .Events[] | (.CloudTrailEvent | fromjson) as $c
    | select($c.eventName == "PutBucketPolicy" or $c.eventName == "PutBucketPublicAccessBlock")
    | select(($c.userAgent // "") | contains($m))
    | {id: $c.eventID, name: $c.eventName, time: $c.eventTime, arn: $c.userIdentity.arn, ua: $c.userAgent}' <<<"$out"
}
