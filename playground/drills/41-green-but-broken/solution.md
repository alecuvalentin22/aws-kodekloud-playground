ROOT CAUSE (two things, the second one hid the first)
  1. A real bug. Priya's first commit changed GET / to
       jsonify(app=os.environ.get("SERVICE_NAME"), version=VERSION)
     and SERVICE_NAME is not set in k8s/deployment.yaml, so production answers
     {"app": null, ...}. The unit test caught it:
       assert body["app"] == "demo-api"   ->   AssertionError: None == 'demo-api'
  2. The release was blocked by that red test, so the second commit made the
     gate unable to fail: the Jenkinsfile passes
       testCommand: 'pip install ... && python -m pytest -q || true'
     `a && b || true` exits 0 whatever pytest says, and the command no longer
     writes test-results.xml. standardPipeline publishes with
     `junit allowEmptyResults: true`, so Jenkins found no report, was not
     allowed to complain, and marked the build SUCCESS. The pytest summary
     ("1 failed, 2 passed") is still in the console log -- nobody reads a
     green build's log -- and the Deploy stage shipped the bug.
  Why it looked like nobody's fault: every build was green, and green is the
  only thing the team looked at. The failure was visible in two places a green
  build teaches you not to open: the log, and the missing "Test Result" link.

FIX (both halves)
  - Jenkinsfile: delete the testCommand override (the library default runs
    pytest with --junitxml and no `|| true`). git revert of the second commit
    is the honest way.
  - app.py: give SERVICE_NAME a default
       app=os.environ.get("SERVICE_NAME", "demo-api")
    or revert the first commit. The test stays exactly as it was.
  - Prove it, do not trust it: main reports tests again (3 here), and a branch
    with a deliberately failing test goes RED. That second proof is what the
    check runs on a throwaway branch, because "my build is green" was the one
    thing nobody could believe any more.

NOT ACCEPTABLE
  - Deleting, skipping or editing the failing test until it passes: the test
    was right. (PENALTY 40.)
  - Keeping `|| true` and "fixing" it by adding junit: failures then make the
    build UNSTABLE (yellow), which still continues to Deploy. The check wants
    FAILURE.

WHAT STOPS IT RECURRING
  - Platform: the library should not let a gate be switched off quietly.
    Stop honouring testCommand overrides that lack --junitxml, set
    allowEmptyResults: false (fail when no report exists: "0 tests" is a
    failure, not a pass), and make the deploy stage require `totalCount > 0`.
    Own the Jenkinsfile in CODEOWNERS so a change to how tests run needs the
    platform team's review.
  - Team: branch protection that requires the check, a flaky test is
    quarantined WITH a ticket and an owner (not by silencing the suite), and a
    smoke test after deploy that asks the running service who it is.

SAY THIS IN THE INTERVIEW
  "A green build only means the pipeline exited 0, and someone had made exiting
  0 unconditional: `|| true` on the test command, and the report step allowed
  to find nothing. So I started from the running service, not the build colour:
  it said its own name was null. I found the real bug in git log, fixed it
  without touching the test, removed the swallowing, and then proved the gate
  works by pushing a branch with a failing test and watching it go red. Then I
  made the library fail on 'zero tests reported', because the next person under
  release pressure will reach for the same `|| true`."
