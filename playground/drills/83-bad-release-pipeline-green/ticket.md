From: Mia (search team)                                       #help-platform

  search-indexer calls demo-api in staging (namespace helm-drill-83) for
  every lookup. Since a few minutes ago every call is "connection refused"
  and our indexing is stalled.

  I looked at your side: the helm-drill-83 job's last build (#2) is GREEN,
  `helm list` says the release is "deployed", but

    kubectl -n helm-drill-83 get pods      ->  0/1 Running, not Ready

  Sam says he only "ran the deploy with a flag to test the alert". Nobody
  remembers what the pipeline is supposed to do when a release is broken.

  Two asks. 1) Get staging serving again, NOW. 2) Tell me why a dead release
  can come out of a green pipeline, make sure it cannot, and show me. I want
  to see a bad deploy fail without anything going down.

  Repo payments/helm-drill-83 (a clone is in ~/platform-playground/helm-drill-83),
  release "demo-api".
