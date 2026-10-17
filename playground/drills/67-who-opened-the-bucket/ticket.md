From: Security team (scanner)                                #help-platform

  The external exposure scanner flagged one of our buckets this morning:
  anonymous GET returns data. Alert text is in
  ~/platform-playground-aws/drill67/alert.txt   (creds: . ./aws-env.sh)

  We need two things from you, in this order:
   1. CONTAIN it now. Do not delete the bucket: legal wants the evidence,
      and whatever is in it is not ours to throw away.
   2. Tell us what happened: which API calls opened it, which identity made
      them, and when (UTC). Put the incident note in
      ~/platform-playground-aws/answers/67.md  -- include the CloudTrail
      EventId, the identity ARN, the userAgent of the caller, the time, and
      one line on how we stop this happening again.

From: Platform on-call                                       #platform-changes

  Heads-up from the last time: CloudTrail (management events) can take
  anywhere from a couple of minutes to ~15 min to show an API call, so if
  you only see the container's own noise, look again before you conclude.
