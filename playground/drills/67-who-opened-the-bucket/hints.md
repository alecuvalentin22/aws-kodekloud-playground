Containment first, two halves: the bucket's block public access settings
(`aws s3api get-public-access-block`) and the bucket policy
(`aws s3api get-bucket-policy`). Re-enable all four BPA flags and remove the
statement that grants access to Principal "*". Do not delete the bucket.
---
Who/when is CloudTrail's job:
  aws cloudtrail lookup-events --lookup-attributes \
    AttributeKey=ResourceName,AttributeValue=<bucket> --max-results 50
Each event has a CloudTrailEvent field that is a JSON STRING: pipe it through
jq (`.Events[].CloudTrailEvent | fromjson`) and read eventName, eventTime,
userIdentity.arn, sourceIPAddress, userAgent and requestParameters. Filter by
EventName=PutBucketPolicy (or PutBucketPublicAccessBlock) to cut the noise.
---
Several calls hit the bucket; only some of them OPENED it. Look at
requestParameters: which PutBucketPublicAccessBlock set all four flags to false, and
which PutBucketPolicy grants s3:GetObject to "*"? The calls you made yourself
while investigating look different: compare their userAgent with the
teammate-script's. Note it in the incident note, with the EventId, the ARN and
the time in UTC. Prevention: account-level S3 Block Public Access, an SCP, an
AWS Config rule / alerting on PutBucketPolicy.
