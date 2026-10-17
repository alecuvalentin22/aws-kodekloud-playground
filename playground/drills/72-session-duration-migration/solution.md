ROOT CAUSE
  Two separate STS limits, one after the other.
  1. A role session cannot be longer than the role's MaxSessionDuration
     (default 1 h, settable 1 h - 12 h). Asking for more fails at once:
       An error occurred (ValidationError) when calling the AssumeRole
       operation: The requested DurationSeconds exceeds the MaxSessionDuration
       set for this role.
     Before the --duration-seconds 7200 "fix" the call used the default 3600 s,
     and the job died mid-run when the token expired:
       An error occurred (ExpiredToken) ... The security token included in the
       request is expired
  2. The job reaches the migrator THROUGH the ci role (VIA_CI=yes): that is role
     chaining, and chained sessions are capped at 1 hour no matter what the
     target role allows:
       An error occurred (ValidationError) when calling the AssumeRole
       operation: The requested DurationSeconds exceeds the 1 hour session limit
       for roles assumed by role chaining.
     So raising MaxSessionDuration alone just moves the error.

FIX (two honest ways)
  A. Long session: MaxSessionDuration 7200 on the migrator (deliberately sized
     for the 110-minute job, not 43200) AND assume it directly, not chained
     (VIA_CI=no; the trust policy already names the lab user).
       real account:  aws iam update-role --role-name ... --max-session-duration 7200
       this account:  iam:UpdateRole is denied -> delete-role + create-role with the
                      same name, the same trust (aws iam get-role ... to copy it) and
                      --max-session-duration 7200
  B. Short sessions that renew (preferred in production): keep 1 hour and re-assume
     before the token dies. In the workspace: SESSION_SECONDS=3600, REFRESH_EVERY=3000
     (about 50 minutes; REFRESH_EVERY + one chunk + a minute must fit in the session).
     This works THROUGH the chain, because 3600 is exactly what chaining allows.
     In real code that is the SDK credential provider (AssumeRole / web-identity /
     credential_process / IMDS refresh themselves) rather than a hand-written loop.
  NOT: MaxSessionDuration 43200 "to be safe" (PENALTY 25: a leaked session lives
  12 h), widening the migrator's trust to the account root or * so that something
  can assume it (PENALTY 30), or running the job with the IAM user's long-lived
  keys (PENALTY 20: nothing expires, nothing rotates, and the keys are not scoped to
  the job).

WHAT STOPS IT RECURRING
  Size sessions from the job (or better, do not size them: let the SDK refresh).
  Know the table: console/AssumeRole default 1 h, role max 12 h, chained 1 h,
  and a session's duration cannot be extended, only replaced. A job longer than a
  session needs a refresh path in its design review, and a test that runs the
  assume with the same settings as production.

HOW THIS DRILL MADE THE FAILURE (honest version)
  break.sh creates two roles with no policies: platform-lab-drill72-ci (trust: the
  lab user) and platform-lab-drill72-migrator (trust: lab user + ci role,
  MaxSessionDuration 3600), plus ~/platform-playground-aws/drill72 with migrate.sh.
  The job only calls sts:GetCallerIdentity, which needs no permission, so no policy
  is attached. check.sh runs migrate.sh --dry-run and judges the session it gets
  (or the refresh the script does) against the 110-minute job. reset.sh deletes
  only the two roles recorded in the state dir.

SAY THIS IN THE INTERVIEW
  "A two-hour job died at exactly one hour: STS sessions default to an hour. The
  tempting fix, --duration-seconds 7200, failed because the role's
  MaxSessionDuration was still 3600; and after raising that it failed again,
  because the job reached the role through another role, and role chaining is
  capped at one hour regardless. I picked refresh over length: one-hour sessions
  renewed from the job, which is what the SDK credential providers do anyway. If
  a long session is really needed, I size MaxSessionDuration for the job, assume
  the role directly, and never go to 12 hours 'to be safe' or fall back to the
  user's long-lived keys."
