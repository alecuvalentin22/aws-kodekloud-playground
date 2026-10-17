From: Dana (data engineering)                                #help-platform

  our nightly data migration takes about 2 hours. since we moved it to the
  migrator role it has been dying at the 60-minute mark:
    An error occurred (ExpiredToken) when calling the GetCallerIdentity
    operation: The security token included in the request is expired
  Radu saw that and added --duration-seconds 7200 to the assume-role call
  yesterday ("2 hour job, 2 hour session, obvious"). Now it does not even
  start:
    An error occurred (ValidationError) when calling the AssumeRole operation:
    The requested DurationSeconds exceeds the MaxSessionDuration set for this role.
  nobody changed the role, I swear. the cutover is tonight, I need the job to
  survive its full run. job is in ~/platform-playground-aws/drill72
  (./migrate.sh --dry-run only gets the session, creds: . ./aws-env.sh)
