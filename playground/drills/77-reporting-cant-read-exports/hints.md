Read the WHOLE error: which action was denied (the LIST or the GET), on which
resource ARN, and whether the role has an identity policy at all. The role has
none: its access comes from the bucket policy (`aws s3api get-bucket-policy
--bucket <name in reporting.env> --query Policy --output text | jq .`).
---
S3 policies use two different kinds of ARN. s3:ListBucket is an action on the
BUCKET (arn:aws:s3:::bucket) and is narrowed with the s3:prefix CONDITION;
s3:GetObject is an action on OBJECTS (arn:aws:s3:::bucket/prefix/*). The
policy has one statement of each kind, both for reports/ only. Fixing one
statement leaves the other: the list works, then the download fails.
---
Edit the bucket policy (you own the bucket): add exports/ to the s3:prefix
condition of the ListBucket statement ("exports/*" next to "reports/*") and
exports/* to the GetObject Resource. Do NOT use bucket/*, s3:*, drop the prefix
condition, or open it to Principal "*" without the aws:PrincipalArn condition;
and do not copy the file into reports/ -- that hides the problem and breaks the
data team's layout.
