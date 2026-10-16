From: Priya (payments team)                                   #help-platform

  we want demo-api to deploy to a new namespace `payments-staging` instead of
  demo-ci from now on (prod comes later). I already changed `namespace:` in our
  Jenkinsfile and pushed. build fails at Deploy with "forbidden". can you give
  the pipeline access? easiest is probably cluster-admin for the jenkins agent?
