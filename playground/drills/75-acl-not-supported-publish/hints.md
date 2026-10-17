Run ./publish.sh and read the whole error. Which API call is it and what
does the message say about the bucket? Then look at the bucket's Object
Ownership setting: `aws s3api get-bucket-ownership-controls --bucket <name>`
(the name is in publisher.env). What does that value mean for ACLs?
---
New buckets default to BucketOwnerEnforced: ACLs are disabled and every
object belongs to the bucket owner. The error is the bucket doing exactly
what it was designed to do. Ask what the ACL in the script was FOR in 2019
("make the object world-readable") and whether you still want that here
(the ticket's second message says you do not).
---
Do not re-enable ACLs (ObjectWriter / BucketOwnerPreferred) and do not
turn off Block Public Access: both are the wrong direction and take points.
Fix the script: drop the --acl flag. Access to objects is given by IAM / the
bucket policy, and to end users with a presigned URL (aws s3 presign) or a
CDN, not by an object ACL.
