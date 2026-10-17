Run ./migrate.sh --dry-run and read the whole error. Then look at the role it
is trying to assume:
  aws iam get-role --role-name platform-lab-drill72-migrator
There are two different numbers in play: how long you ASK for
(--duration-seconds) and how long the role ALLOWS (MaxSessionDuration).
---
Raising the role's limit is the obvious move. In a normal account that is
`aws iam update-role --max-session-duration 7200`. This account refuses
iam:UpdateRole (and UpdateAssumeRolePolicy): the role has to be recreated with
the same name, the same trust (copy it from get-role) and --max-session-duration.
Do it, run the dry-run again, and read the NEW error: it is a different limit.
---
Role chaining -- credentials of a role (the ci role) used to assume another role
-- is capped at ONE HOUR, whatever MaxSessionDuration says. So there are two
honest ways out: (a) assume the migrator directly (the trust already names the
lab user) with a MaxSessionDuration of 7200, or (b) keep 1 hour and make the job
renew its credentials before they expire (job.env: SESSION_SECONDS, REFRESH_EVERY;
README.md in the workspace says how maybe_refresh works). Do not use 43200 "to
be safe", do not widen the trust, and do not run the job with the user's keys.
