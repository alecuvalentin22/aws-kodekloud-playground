ROOT CAUSE
  Terraform takes the state lock before it plans an apply and releases it when
  the run ends. A SIGKILL (laptop sleep, closed terminal, a CI runner reaped)
  gives it no chance to release. With the S3 backend and `use_lockfile = true`
  (Terraform >= 1.10) the lock is an object next to the state,
  <state key>.tflock, created with a conditional write (If-None-Match: *), so a
  second writer gets a 412 and Terraform prints:
    Error: Error acquiring the state lock
    ... PreconditionFailed ...
    Lock Info:
      ID:        <uuid>
      Path:      <bucket>/<key>
      Operation: OperationTypeApply
      Who:       priya@ci-runner-eu-2
      Version:   1.14.x
      Created:   <hours ago>
  Nothing else is wrong: the state is intact, only the claim is stale.

FIX
  1. Confirm nobody is applying. The lock says who and when; ask Priya, look at
     the CI runs / her terminal. An apply that long ago on a tiny root cannot
     still be running. This step is the whole job: force-unlock on a lock
     that is alive corrupts state.
  2. terraform force-unlock <ID>       (the ID from the error; it refuses a wrong one)
  3. terraform plan -- it shows Priya's change (terraform_data.migration_marker
     to add), because her apply never reached the state. Read it, apply it (or
     revert it if it should not go out). Plan again: "No changes".
  NOT: -lock=false (two writers on one state), deleting the .tflock object by
  hand (what force-unlock does, minus the ID check), deleting the state object
  (the next plan wants to create everything again, and with real resources that
  is duplicates or an outage).

WHAT STOPS IT RECURRING
  Applies from CI (one runner, `-lock-timeout`, a job that is cancelled
  cleanly), not from laptops; a pipeline step that runs force-unlock only
  after a human confirms; short applies. State bucket versioning (already on
  here) is the safety net if a state is ever damaged: previous version restore.

HOW THIS DRILL MADE THE LOCK (honest version)
  break.sh runs a real `terraform apply` against the lab's S3 backend and
  kill -9s it while a local-exec step is sleeping, so the lock object is the one
  Terraform itself wrote. It then rewrites only the lock's Who and Created
  fields (to look like a teammate's lock from three hours ago); the ID and the
  rest are untouched. Resources are terraform_data only: nothing in AWS but
  two S3 objects (state, lock) in the lab's own state bucket. The older
  DynamoDB lock table is not used (not needed with Terraform >= 1.10, and not
  free of cost or permissions questions).

SAY THIS IN THE INTERVIEW
  "A stale lock is a question, not an error: is anyone still applying? I read
  the lock info -- who, when, which operation -- and confirmed with the owner
  and the CI runs before touching it. Then terraform force-unlock with the ID,
  which checks it is the lock I meant to release, and a plan before any apply
  because the killed run's change was still pending. I would never use
  -lock=false or delete the state: the lock exists to stop two writers, and the
  state is the only record of what Terraform owns. Afterwards I moved that
  root's applies into CI so a closed laptop cannot hold a lock."
