Compare THREE things: the form Jenkins shows you under "Build with Parameters",
the parameters block in the Jenkinsfile on main, and what the build's console
printed. Do the names in the form match the names the pipeline reads?
Open the failed run's "Parameters" page too: what did Jenkins record as input?
---
Jenkins only learns a job's parameter list by RUNNING its Jenkinsfile: the
parameters {} block updates the job when a build starts, so the form always
shows the list from the previous run. Priya merged the rename but nobody ran
the job afterwards. Sam's values were recorded under the OLD names; for the
new names the run was given nothing, so Jenkins quietly supplied the defaults
(the first choice, "staging"; an empty string) and the pipeline's own
fallbacks did the rest.
---
Two fixes, both needed. (1) Make Jenkins learn the new form: run the job once
(it can be a dry run or a build that is expected to stop early), and check
"Build with Parameters" shows TARGET_ENV / IMAGE_TAG / DRY_RUN.
(2) In the Jenkinsfile, stop turning "nothing was given" into "deploy the
default": a release with no IMAGE_TAG must fail loudly (error(...)) instead of
becoming `latest`, and TARGET_ENV must come from what the user chose. Push the
change, then run the job once more so the form is in line with main.
