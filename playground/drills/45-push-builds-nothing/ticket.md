From: Sam (payments team)                                     #help-platform

  since this morning a push to demo-api does nothing. no build, no red, no
  green, just silence. Build Now works, so the pipeline itself is fine, but
  we've been clicking it after every push for two hours and it's getting old.
  my README change from 40 minutes ago never built. did the Gitea connection
  die?

From: Jordan (platform team)                                  #platform-changes

  agent capacity is tight until the release freeze ends, so I tuned the
  demo-api job to stop feature-branch pushes from eating agents. should be
  invisible to everyone else. will put it back after the freeze
