ROOT CAUSE
  The script asks S3 for something the bucket has switched off. publish.sh does
    aws s3 sync assets s3://<bucket>/site --acl public-read
  and the error is
    upload failed: assets/app.js to s3://<bucket>/site/app.js
    An error occurred (AccessControlListNotSupported) when calling the PutObject
    operation: The bucket does not allow ACLs
  New buckets have Object Ownership = BucketOwnerEnforced (the default since
  April 2023): ACLs are DISABLED, every object is owned by the bucket owner
  whoever uploads it, and any request that carries an ACL other than
  bucket-owner-full-control is refused. The old bucket was created before that
  (ObjectWriter: the uploader owns the object and may set its ACL), which is why
  the same script "worked for years". Nothing is misconfigured: the new bucket
  is the secure default.

  Check it: aws s3api get-bucket-ownership-controls --bucket <name>
    -> ObjectOwnership: BucketOwnerEnforced

FIX (in the script)
  1. Remove --acl public-read from the sync/cp. Objects are owned by the bucket
     owner, nothing else is needed for the upload.
  2. Access is given the modern way, NOT by an object ACL:
     - in-account principals: IAM policies;
     - other accounts / specific principals: a bucket policy;
     - end users: presigned URLs (aws s3 presign) or CloudFront with an origin
       access control (the bucket stays private, the CDN gets read access
       through the bucket policy).
     Here security says the bucket is not public, so the site keeps using signed
     URLs / the CDN.
  3. ./publish.sh, then aws s3 presign s3://<bucket>/site/app.js | curl it: 200;
     curl the plain object URL: 403.
  NOT: put-bucket-ownership-controls ObjectWriter/BucketOwnerPreferred (re-enables
  ACLs: PENALTY 40; and the next error would be AccessDenied, because Block Public
  Access still refuses public ACLs), nor turning Block Public Access off or adding a
  public bucket policy (PENALTY 40: publishes the assets to the world; the check
  puts the secure configuration back before judging the script).
  (Passing --acl bucket-owner-full-control is accepted by a BucketOwnerEnforced
  bucket and is the right flag for cross-account uploads, but here it is just noise.)

WHAT STOPS IT RECURRING
  Update the wiki page; new-bucket template documented as "ACLs off, access by
  policy"; scripts that publish to S3 reviewed for --acl / put-object-acl; a CI
  smoke test that publishes to a fresh bucket from the template; an SCP or
  Config rule that denies ACL-enabled buckets so nobody "fixes" this the other way.

HOW THIS DRILL MADE THE FAILURE (honest version)
  break.sh creates one tagged bucket (platform-lab-drill75-<account>-<rand>) with
  new-bucket defaults (BucketOwnerEnforced, block public access on) and a
  workspace ~/platform-playground-aws/drill75 whose publish.sh syncs ./assets
  with --acl public-read. check.sh runs publish.sh itself with fresh assets,
  confirms they arrived, that an anonymous GET is 403 and a presigned URL works,
  and puts back ownership / Block Public Access if they were changed. reset.sh
  empties and deletes only the bucket recorded in the state dir.

SAY THIS IN THE INTERVIEW
  "The publish script failed with AccessControlListNotSupported after a move to
  a new bucket. New S3 buckets default to BucketOwnerEnforced, which disables
  ACLs; our 2019 script sent --acl public-read and the bucket refused it. I did
  not re-enable ACLs or open the bucket: security wanted it private. I removed
  the ACL from the script and left access to IAM and the bucket policy, with
  presigned URLs for the site, and confirmed with an anonymous request (403)
  and a presigned one (200). Then I updated the wiki so the next person does not
  copy the old flag."
