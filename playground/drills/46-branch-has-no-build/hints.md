"No job at all" is a different question from "a red job". Open demo-api in
Jenkins and read the Scan Multibranch Pipeline Log (left menu). What does it
say about main? What does it say about Sam's branch, if anything?
---
A branch can be missing for two separate reasons, and you may have both.
(1) Jenkins is not LOOKING at it: job > Configure > Branch Sources > Git >
Behaviours. (2) Jenkins looks and rejects it: the scan log says "Does not meet
criteria" when the file at the job's Script Path is not in that branch.
Fix the first, scan again, and read the log again before you touch anything else.
---
Behaviours has "Filter by name (with wildcards)" with an include list. Widen it
to the team's prefixes (feature/* fix/* release/*, plus main). Once the branch is
seen, the log will say it has no Jenkinsfile: look at what IS there with
  git -C ~/platform-playground/demo-api fetch && git ls-tree --name-only origin/feature/refund-endpoint
and fix THE BRANCH. Do not change the job's Script Path: main uses it.
