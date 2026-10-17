ROOT CAUSE
  The reporting role's access is a bucket policy with two statements, both scoped
  to reports/:
    ReportingListReports  s3:ListBucket on arn:aws:s3:::BUCKET (the bucket ARN),
                          Condition StringLike s3:prefix = reports/*
    ReportingReadReports  s3:GetObject on arn:aws:s3:::BUCKET/reports/* (object ARN)
  The exporter moved to exports/, which neither statement covers. fetch.sh fails
  first on the LIST:
    An error occurred (AccessDenied) when calling the ListObjectsV2 operation:
    User: arn:aws:sts::<acct>:assumed-role/platform-lab-drill77-reporting/reporting-fetch
    is not authorized to perform: s3:ListBucket on resource: "arn:aws:s3:::<bucket>"
    because no identity-based policy allows the s3:ListBucket action
  and, once the list is fixed, on the GET (s3:GetObject on .../exports/2026-10.csv).
  Two statements, two ARN kinds: that is the lesson.

FIX
  aws s3api get-bucket-policy ... | jq .  -> edit -> aws s3api put-bucket-policy
    ListBucket statement : s3:prefix StringLike ["reports/*","exports/*"]
    GetObject statement  : Resource ["arn:aws:s3:::B/reports/*","arn:aws:s3:::B/exports/*"]
  Keep Principal "*" with aws:PrincipalArn = the role ARN (or name the role).
  NOT: bucket/* or s3:* or Principal "*" without the PrincipalArn condition
  (PENALTY 40: raw data will land in this bucket), ListBucket without an s3:prefix
  condition (PENALTY 20: the role could list the whole bucket), or copying the
  file into reports/ (PENALTY 15: the symptom disappears, the layout and the
  least-privilege design do not).

NOTES
  - The wording is 'no identity-based policy allows...' even though a bucket policy exists: it is
    simply 'nothing allowed it'. Read the action and resource, then look at BOTH policy types.
  - A listing request with --prefix exports/ is evaluated against s3:prefix, so
    "exports/*" (StringLike) allows "exports/" and anything below it.
  - s3:ListBucket on an object ARN, or s3:GetObject on the bucket ARN, matches
    nothing: the classic wrong-ARN bug.
  - Same account: a bucket policy that names the principal is enough, no identity policy.

HOW THIS DRILL MADE THE FAILURE (honest version)
  break.sh creates one role (no policies; DeletePolicy/PutRolePolicy are denied here),
  one tagged bucket with two objects and the two-statement policy, and a workspace
  with fetch.sh. check.sh runs fetch.sh for exports/ and reports/ and reads the
  live policy; reset.sh deletes only what is recorded in the state dir.

SAY THIS IN THE INTERVIEW
  "AccessDenied on a new prefix only. I read which action and resource were
  denied: first the ListBucket on the bucket ARN, then GetObject on the object
  ARN. They are separate statements with separate ARN forms; the list is narrowed
  by an s3:prefix condition and the get by the resource path. I added exports/ to
  both and nothing else. I did not use bucket/* or s3:* and I did not copy the
  files across: the point of per-prefix grants is that raw data later in the
  same bucket stays unreadable."
