Start from what is running, not from the colour of the build. Ask the service
itself what it says it is (the playground's demo-api is on localhost:30095),
then open the last main build in Jenkins: is there a "Test Result" link? Read
the Test stage's console to the end -- the last lines of pytest are there.
---
`git log -p` in payments/demo-api shows two commits from Priya, minutes apart.
One changes behaviour, one changes how the Jenkinsfile runs the tests. Look at
the exit code of `a && b || true`, and at what Jenkins does with a test
report that does not exist (allowEmptyResults in platform-lib).
---
Two fixes, and you need both. (1) Make a failing test fail the build again:
remove the swallowing from the Jenkinsfile (or the whole testCommand override,
the library default already writes the report). (2) Fix the app so the test
passes for the right reason -- the test is correct, do not skip or edit it.
Then prove it: the main build must report tests, and a branch with a failing
test must go red.
