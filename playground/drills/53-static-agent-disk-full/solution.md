ROOT CAUSE
  The static agent's workspace volume is small (96 MB since the disk swap) and
  nothing on it is ever cleaned. A static agent keeps every workspace until
  someone removes it, and this one filled up two ways:
    - the workspace of a job that was DELETED months ago (payroll-batch, 30 MB):
      Jenkins' workspace cleanup only handles jobs it still knows or
      workspaces unused for 30 days on a timer the team never tuned, and
      nothing removes it for you from a machine outside the cluster
    - ledger-export itself writes a 28 MB CSV into out/ on every build and
      never deletes it: +28 MB per night
  The symptoms came in two stages. Build #3 died of
      tr: write error: No space left on device
  and Jenkins' disk-space monitor took the node out of service
      Disk space is below threshold of 16.00 MiB. Only 9.80 MiB out of 96.00 MiB left on /home/jenkins/agent.
  so the retry just waits ("static-01 is offline"). The mails "disk-space: low
  on static-01" (health check, warning at 32 MiB) were the early warning
  nobody read. A pod agent has none of this: its disk is the pod's and is
  deleted with it.

FIX
  1. Make room: docker exec pg-static-01 du -sh /home/jenkins/agent/workspace/*
     then remove the dead job's workspace and ledger-export's out/ (or Wipe Out
     Workspace on the job once the node is online).
  2. Nodes -> "Refresh status": Jenkins re-checks the disk now instead of at the
     next monitor run (about 5 minutes); the node comes back online by itself.
  3. Stop the growth, in the Jenkinsfile:
       post { always { cleanWs() } }                       // nothing left behind
       options { buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '5')) }
     Prove it: run the job a few times and watch `df`: it stays flat.
  4. Leave the thresholds alone.

NOT the fix
  - Lowering or disabling the disk-space threshold (node -> Configure -> Node
    Properties, or Manage Jenkins -> Nodes -> Configure monitors): the node comes
    back online, and the next export dies half-way of ENOSPC, with a partial
    file. The monitor is the smoke detector; do not take its battery out.
  - Only deleting files: it buys three nights.
  - Only growing the disk: same, plus nobody learns the pipeline leaks.

WHAT STOPS IT RECURRING
  - Pipelines clean up after themselves (cleanWs in post always; for crash-safety
    also at the start, drill 52).
  - Build discarders on every job: records and archived artifacts on the
    CONTROLLER's disk are the same problem one level up.
  - A scheduled sweep for workspaces of deleted jobs / unused for N days, and an
    alert on disk free < 30% on every static agent BEFORE the monitor's offline
    threshold (the warning threshold exists for that).
  - Output that must be kept goes to the artifact store, not to the agent.

SAY THIS IN THE INTERVIEW
  "Every static build was red, then the node went offline. I looked at why Jenkins
  took it out: the disk-space monitor, which is doing its job. On the box,
  du showed a dead job's workspace and our own export growing 28 MB a build.
  I freed the space, refreshed the node, then fixed the leak: cleanWs after
  every build and a build discarder, and proved it with four exports in a row
  and a flat df. I did not lower the threshold; that turns an offline node you
  can see into a build that dies half-way through the close. And I asked for an
  alert at the warning threshold, since the mails for two weeks said so."

  Static vs dynamic: pods get a fresh, bounded disk per build; a static agent's
  disk is a shared, long-lived resource you have to garbage-collect yourself.
