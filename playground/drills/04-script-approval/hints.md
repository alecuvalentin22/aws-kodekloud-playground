Before deciding, find out what approving it would mean. Where does a line of
Groovy at the top of a Jenkinsfile run -- on the agent pod, or on the
controller? And what can `"...".execute()` run?
---
Approving it would let ANY pipeline on this Jenkins run any process as the
Jenkins user on the controller (credentials, secrets, all jobs). It would not
even work: on the controller there is no checkout of this repo to rev-parse.
---
QA's request is still fair. The data already exists: env.GIT_COMMIT inside
a stage, or env.IMAGE_TAG, which platform-lib computes. The library runs
trusted, so a platform-wide `currentBuild.displayName = ...` in
standardPipeline.groovy serves every team -- in ~/platform-playground/platform-lib.
