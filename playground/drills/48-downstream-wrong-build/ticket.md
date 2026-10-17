From: Sam (payments team)                                     #help-platform

  I fixed the version string in demo-api and ran rel-build. Green. rel-deploy
  ran right after it. Green. But relsvc in the rel-demo namespace still runs
  the OLD image:

    kubectl -n rel-demo get deploy relsvc -o wide

  shows the same image as this morning. I ran rel-build twice more, same
  thing. The new image IS in the registry, I looked. So rel-deploy is "green"
  and deploys... nothing? Or the wrong thing? I'm lost.

From: Priya (payments team)                                   #platform-changes, last week

  rel-deploy: renamed the parameter TAG -> IMAGE_TAG so it matches the release
  job. And if it is started with no tag it now re-applies whatever is running,
  so a failed deploy can be re-run safely.

  (The jobs' code is in ~/platform-playground/rel-pipelines.)
