From: Sam (payments team)                                     #help-platform

  I pushed feature/refund-endpoint 25 minutes ago and there is no build for
  it. Not red, not green: there is no job for the branch under demo-api at
  all, only main. I have pressed "Scan Multibranch Pipeline Now" four times.
  The branch is right there in Gitea. I need CI on it before I can open the
  PR. Is Gitea not telling Jenkins, or what?

From: Jordan (platform team)                                  #platform-changes, last Friday

  demo-api was creating a job for every branch anybody ever pushed (140+ of
  them, all eating controller memory), so I tidied the job's branch source.
  Should be invisible to everyone else.

  Reminder: the team's branch convention is feature/*, fix/* and release/*.
