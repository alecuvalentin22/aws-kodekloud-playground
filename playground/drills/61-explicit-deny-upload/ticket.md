From: Mihai (release engineering)                            #help-platform

  the release-notes upload started failing this morning:
    An error occurred (AccessDenied) when calling the PutObject operation:
    User: arn:aws:iam::<acct>:user/<our release user> is not authorized to
    perform: s3:PutObject on resource: "arn:aws:s3:::<bucket>/releases/..."
    with an explicit deny in a resource-based policy
  but our IAM user has s3:PutObject on that bucket -- I checked the policy
  twice, there is even an s3:* in it. nothing changed on the IAM side.
  I did "simplify" upload.sh yesterday (dropped some flags I didn't
  understand), but it is a plain put-object, how can that be denied??
  it's in ~/platform-playground-aws/drill61 (creds: . ./aws-env.sh)

From: Security team                                          #platform-changes

  FYI we put guardrails on the release buckets last week (SEC-318).
  No action needed from teams.
