Run ./upload.sh and read the WHOLE error, not just "AccessDenied". It says
what kind of policy denied the request, and whether it was a missing allow or
an explicit deny. Then: whose policy is it -- the IAM user's, or something
attached to the other side (the bucket)? `aws s3api get-bucket-policy
--bucket <name>` (the name is in uploader.env).
---
An allow in the IAM policy cannot beat a Deny anywhere. Read the bucket
policy's Deny statements as conditions on the REQUEST: what must a PutObject
look like to get past each one? Then read upload.sh as the request it makes.
There are two Deny statements; fixing the request for one does not help
against the other, and the error text is the same for both.
---
The guardrail is the security team's, and it is reasonable -- do not delete
or weaken it. Change the client: send the server-side-encryption header
(`--server-side-encryption AES256` on put-object) and talk to S3 over
HTTPS (drop the http:// --endpoint-url). Turning off TLS verification does not
make anything better: it is not what the policy checks.
