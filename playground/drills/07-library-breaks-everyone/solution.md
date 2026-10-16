ROOT CAUSE
  Jenkins loads platform-lib at its default version, `main` -- unpinned. A
  refactor on main renamed the required parameter `context` to `path`, so
  every unchanged Jenkinsfile failed at once with "path is required". A
  shared library's blast radius is every team that uses it.

FIX, IN ORDER
  1. Stop the bleeding: git revert the commit on platform-lib main, push,
     re-run builds. (Not a force-push: main is shared.)
  2. Tell the teams, with an ETA, in the channel they asked in.
  3. Make it unrepeatable: pin consumers to a tag (@Library('platform-lib@v1.0.0')
     or defaultVersion in JCasC), release library changes as tags, roll new
     tags out to one canary team first.
  4. Re-land the rename properly: accept both `path` and `context`, warn on
     the old one, release it as v1.1.0, remove `context` in a later major.

SAY THIS IN THE INTERVIEW
  "A shared library is a platform with N customers, so a breaking change is an
  outage for N teams. I reverted first -- forward, with git revert, because
  main is shared -- and posted status. Then the real fix: teams pin a tag, we
  release the library like any other dependency, and breaking changes ship as
  'accept both, deprecate, remove'. That's the answer to your lead's second
  question, and it's the one they actually care about."

  Background: platform-lab ci/shared-library/vars/standardPipeline.groovy header,
  and docs/ci-track.md "How do you share pipeline code across teams?".
