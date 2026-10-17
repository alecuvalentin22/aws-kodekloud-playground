ROOT CAUSE
  A script run as the lab IAM user (userAgent contains exec-env/platform-lab-tidy-script)
  removed the bucket's guardrails and made it world-readable with TWO management
  API calls:
    1. PutBucketPublicAccessBlock  with all four flags false (the guardrail off)
    2. PutBucketPolicy             Allow s3:GetObject, Principal "*", on exports/*
  The first alone does nothing public; the second is what the scanner saw. They
  are a few seconds apart, next to a harmless
  PutBucketLifecycle(Configuration) from the same script. (The script's Get* calls
  -- GetBucketAcl, GetBucketLocation, GetPublicAccessBlock... -- are read-only
  bucket-level S3 calls and do NOT appear in LookupEvents at all.) The bucket's own earlier PutBucketPublicAccessBlock (all true)
  is also in the trail: read requestParameters, not just the name.

CONTAIN FIRST (do not delete the bucket: that destroys the evidence)
  aws s3api put-public-access-block --bucket B --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api delete-bucket-policy --bucket B
  Re-test anonymously: curl -I https://B.s3.amazonaws.com/exports/q3-summary.csv -> 403.
  Save the policy first if you want it for the note:
  aws s3api get-bucket-policy --bucket B > evidence.json

FIND WHO/WHAT/WHEN (CloudTrail, management events)
  aws cloudtrail lookup-events --lookup-attributes \
      AttributeKey=ResourceName,AttributeValue=B --max-results 50 --output json |
    jq -r '.Events[] | (.CloudTrailEvent | fromjson)
           | [.eventTime, .eventName, .eventID, .userIdentity.arn, .sourceIPAddress,
              .userAgent, (.requestParameters | tostring)] | @tsv'
  Or filter by event: AttributeKey=EventName,AttributeValue=PutBucketPolicy
  (then pick the one whose requestParameters name the bucket).
  .CloudTrailEvent is a JSON string: it has to go through fromjson. Fields to read:
    eventTime (UTC), eventName, eventID, userIdentity.arn / type / accessKeyId,
    sourceIPAddress, userAgent, requestParameters, errorCode (a failed call is
    in the trail too).
  The note (answers/67.md) needs: both API calls, the EventId, the ARN, the time
  in UTC, the userAgent marker, one line of prevention.

WHAT CLOUDTRAIL DOES NOT SHOW, AND HOW LATE IT SHOWS
  - Delivery: management events show up in LookupEvents typically 1-3 minutes
    after the call, sometimes up to ~15 -- and one by one: in the live run the
    PutBucketPolicy was visible after ~70 s while the PutBucketPublicAccessBlock
    sent in the same second took several minutes more. "I see nothing" right after an incident
    is not "nothing happened". LookupEvents covers only the last 90 days and
    allows 2 requests/second per account, one attribute per query.
  - Object-level S3 activity (GetObject, PutObject, DeleteObject, ListObjects)
    is a DATA event. It is NOT recorded unless a trail has data events enabled
    for that bucket. So CloudTrail cannot tell you here whether anyone actually
    DOWNLOADED q3-summary.csv while the bucket was public. S3 server access logs
    (or a trail with S3 data events, enabled in advance) would. Say that in the
    note: "exposure window known, access during the window unknown".
  - The identity is the lab's IAM user in this drill, for the "teammate" and for
    you alike (one set of keys). The userAgent (exec-env/...) is what tells the
    script's calls apart from yours. In real life: userIdentity.arn, the
    sourceIPAddress and the access key id.

WHAT STOPS IT RECURRING
  - Account-level S3 Block Public Access ON (s3control put-public-access-block):
    then the bucket-level switch-off does nothing.
  - An SCP denying s3:PutBucketPublicAccessBlock / s3:PutAccountPublicAccessBlock
    (and PutBucketPolicy with public principals) except for a named admin role.
  - An AWS Config rule (s3-bucket-public-read-prohibited) and an alert (EventBridge
    on PutBucketPolicy / PutBucketPublicAccessBlock, or GuardDuty/Macie).
  - Scripts that change guardrails must not run with a human's broad keys.

HOW THIS DRILL MADE THE FAILURE (honest version)
  break.sh creates one tagged bucket (platform-lab-drill67-<account>-<rand>) with
  block public access on, then runs a "tidy script" with
  AWS_EXECUTION_ENV=platform-lab-tidy-script (the CLI puts it in the userAgent as
  exec-env/...) that does routine calls and the two culprit ones. It polls
  LookupEvents until the culprit events are visible before it hands you the ticket.
  The identity is the same IAM user as yours: that is the honest limitation.
  check.sh looks the events up again and compares the note with them (EventId,
  ARN, userAgent marker, time); reset.sh empties and deletes only the bucket
  recorded in the state dir.

SAY THIS IN THE INTERVIEW
  "The scanner said a bucket was public. I contained it first -- block public
  access back on, the public policy removed, anonymous GET now 403 -- and kept the
  bucket, because deleting it destroys the evidence. Then CloudTrail: lookup-events
  by bucket name, CloudTrailEvent through jq, found PutBucketPublicAccessBlock with
  all four false followed seconds later by PutBucketPolicy granting GetObject to *,
  from a script's userAgent, with the IAM user's ARN, the source IP and the UTC
  time. I wrote that down with the EventIds, and noted what I could not say: object
  reads are data events, which that account did not log, so I could say how long it
  was exposed but not whether anyone downloaded anything. Prevention: account-level
  block public access, an SCP on the guardrail APIs, a Config rule and an alert on
  those two API calls, and S3 data events/access logs on sensitive buckets."
