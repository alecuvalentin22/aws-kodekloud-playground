Build Now works, so the build is fine; the question is what starts a build
when someone pushes. In THIS Jenkins nothing is pushed to it: the demo-api
folder re-scans Gitea every minute (branch indexing) and builds what changed.
Open the folder page and read the "Scan Multibranch Pipeline Log" (the latest
scan). Does it see Sam's commit? What does it do next?
---
The log sees the change and then says, for main, "Did not schedule build for
branch". Something on the job tells Jenkins not to build on SCM changes. Look
at Configure -> Branch Sources -> Property strategy. Jordan's message in
#platform-changes is the clue. Also ask where the job's real definition lives:
it is generated from code (JCasC + Job DSL), and that code never had this.
---
Remove "Suppress automatic SCM triggering" from the branch sources (Configure
in the UI), or put the job back as code defines it: Manage Jenkins ->
Configuration as Code -> Reload existing configuration. Then prove it the way
Sam would: push a commit to a branch and a build appears on its own within a
scan interval. Don't add a pollSCM or cron to the Jenkinsfile to compensate.
