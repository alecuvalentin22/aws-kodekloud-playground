ROOT CAUSE
  The request was denied by the BUCKET, not by IAM. The error says so:
    An error occurred (AccessDenied) when calling the PutObject operation:
    User: arn:aws:iam::<acct>:user/<user> is not authorized to perform:
    s3:PutObject on resource: "arn:aws:s3:::<bucket>/releases/..."
    with an explicit deny in a resource-based policy
  "resource-based policy" = the bucket policy; "explicit deny" = a Deny
  statement matched. (A plain missing allow reads "...because no
  identity-based policy allows the s3:PutObject action"; a deny in the user's own
  policy reads "explicit deny in an identity-based policy".) An allow in IAM,
  even s3:*, can never override a Deny: evaluation is explicit deny first.

  The security team's bucket policy (SEC-318) has two Deny statements:
    DenyUnencryptedUploads  s3:PutObject unless the s3:x-amz-server-side-encryption
                            header is AES256 or aws:kms (StringNotEquals)
    DenyInsecureTransport   s3:* when aws:SecureTransport is false (plain HTTP)
  The "simplified" upload.sh sends neither the header nor HTTPS (it points
  --endpoint-url at http://s3.amazonaws.com), so BOTH match. The message is the
  same for either, which is the trap: adding only the header (or only dropping
  http://) still fails.

FIX (on the client)
  1. aws s3api get-bucket-policy --bucket <name> --query Policy --output text | jq .
     Read each Deny as a condition on the request.
  2. In upload.sh: add --server-side-encryption AES256 (or aws:kms), remove
     the http:// --endpoint-url (the default endpoint is HTTPS).
  3. ./upload.sh -- then head-object shows ServerSideEncryption: AES256.
  NOT: deleting the bucket policy or editing a Deny out (the check puts the
  recorded policy back and takes PENALTY 50: it is the security team's control
  and it is right), or --no-verify-ssl (PENALTY 20: the policy checks that TLS
  is used, not that the certificate is verified; it changes nothing about the
  denial and removes a protection).

WHAT STOPS IT RECURRING
  Guardrails announced with the change, and the same condition in the shared
  upload helper; a CI test that uploads to a staging bucket carrying the same
  policy; the SDK/CLI wrapper that sets encryption by default. If a guardrail
  is really wrong, the fix is a request to the owner of the bucket policy
  (a PR on their Terraform), not a workaround on your side.

HOW THIS DRILL MADE THE FAILURE (honest version)
  break.sh creates one tagged bucket (platform-lab-drill61-<account>-<rand>,
  block public access) with exactly the two Deny statements above and a
  workspace ~/platform-playground-aws/drill61 whose upload.sh is the "simplified"
  version. Nothing else in the account is touched. check.sh runs upload.sh itself
  with a fresh object, confirms it is stored encrypted, and compares the live
  policy with the recorded one (putting the recorded one back if it was
  weakened, so the uploader is judged against the real guardrail). reset.sh
  empties and deletes only the bucket recorded in the state dir.

SAY THIS IN THE INTERVIEW
  "AccessDenied while the IAM policy clearly allowed PutObject: I read the
  whole message instead of the first line. 'Explicit deny in a resource-based
  policy' means the bucket policy, and a Deny always wins over any Allow. The
  bucket policy had two guardrails from security, encryption header required
  and TLS required, and our script, which someone had simplified, sent neither.
  I fixed the client -- SSE header and HTTPS -- and left the guardrail alone,
  and mentioned that one error message covers both denies, so I checked both
  conditions rather than stopping at the first fix. I would never disable TLS
  verification or delete the policy to make a job green."
