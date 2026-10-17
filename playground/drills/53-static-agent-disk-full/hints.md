Two symptoms, one cause. Start with the node page (Manage Jenkins -> Nodes ->
static-01): why does Jenkins say it is offline? Then look at the machine, not
at Jenkins:
   docker exec pg-static-01 df -h /home/jenkins/agent
   docker exec pg-static-01 du -sh /home/jenkins/agent/workspace/*
The monitor is doing its job: it takes a node out of service BEFORE builds
crash on it. Who is using the space, and since when?
---
Two things fill the volume: a workspace of a job that was deleted months ago
(nothing ever removes it from a static agent), and ledger-export itself:
every build writes a 28 MB CSV into out/ and nothing deletes it, so the
workspace grows by 28 MB per build. The 96 MB volume was always going to fill.
Free the space (rm on the box, or Wipe Out Workspace once the node is back),
then Nodes -> "Refresh status" makes Jenkins re-check the disk instead of
waiting for the next monitor run.
Lowering or disabling the disk-space threshold would "bring it back online" and
leave you with builds that die of ENOSPC halfway, so it is a trap.
---
Clean up AND stop the growth. In ledger-export's Jenkinsfile: cleanWs() in
post { always { ... } } (ws-cleanup plugin) so a build leaves nothing behind,
and options { buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '5')) }
so build records and archived exports do not pile up on the controller either.
Then run it a few times and watch `df`: it must stay flat. The thresholds stay as
they are. (And tell Jordan the leftover workspace of the deleted job is gone.)
