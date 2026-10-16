ROOT CAUSE
  @Library('platform-lib@v2') asks for a ref that does not exist. The library
  only has the tag v1.0.0 (and main). Jenkins resolves the library before the
  first stage, so the build dies in seconds with:
    ERROR: Could not resolve v2
    ... No such library resource / Could not find any definition of libraries [platform-lib@v2]

FIX
  @Library('platform-lib@v1.0.0') _       (pinned: best)
  @Library('platform-lib') _              (default version: works, unpinned)

WHAT STOPS IT RECURRING
  The wiki was wrong. Fix the wiki, and publish library releases as tags with
  a changelog, so "which version do I use" has one answer.

SAY THIS IN THE INTERVIEW
  "A build that fails before the first stage is not the developer's code. It is
  Jenkins setting up: SCM checkout, library resolution, agent provisioning. I
  read the console from the top, saw the library ref did not exist, and pointed
  the team at the released tag. Then I fixed the doc that misled them, because
  the next team would have copied it too."

  Same failure, documented on EKS: platform-lab drills/18 section 10.
