ROOT CAUSE
  Jenkins runs every `sh` step with -x, which prints each command with its
  variables expanded. With `set +x` removed, the login step echoes the token
  minted by `aws ecr get-login-password`. From the EKS lab write-up
  (drills/18 section 1b):
    + TOKEN=eyJwYXlsb2FkIjoi...        <- the full registry token, in the build log
  withCredentials() masks secrets IT binds; a token minted inside the script
  is not bound, so nothing masks it.

FIX
  1. Library: `set +x` as the first line of any sh that handles a secret.
     Rebuild so pipelines still push.
  2. Delete every build record whose log holds a token (the check scans all
     retained builds of every branch).
  3. Tell security what leaked, for how long, to whom (Job/Read holders).

CAN YOU REVOKE IT? (what to say, honestly)
  - There is no ECR API to revoke one authorization token. It is valid for
    12 hours from issue (drills/18 section 1b: "push to the registry for 12
    hours").
  - What you CAN do: delete the logs (stops further copies); check CloudTrail
    for ECR push activity in that window from principals you don't expect;
    and cut the credentials it was minted from -- for a role, IAM's "revoke
    active sessions" (a deny on aws:TokenIssueTime). Whether that also kills an
    already-issued ECR token is worth testing before you promise it.
  - Here the token belongs to the NODE role, so the blast radius is every pod
    on those nodes -- drill 14 is the structural fix.

SAY THIS IN THE INTERVIEW
  "I check what -x prints before I trust a pipeline with a secret. Here the
  fix was one line, but the incident wasn't: I also had to purge the logs that
  already held the token and tell security plainly that an ECR token can't be
  revoked on its own -- it ages out in 12 hours -- so we looked at CloudTrail
  for that window and moved push off the node role."

  Source: platform-lab drills/18 section 1b.
