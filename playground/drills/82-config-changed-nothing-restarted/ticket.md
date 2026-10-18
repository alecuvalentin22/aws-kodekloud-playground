From: Tomas (QA, release train)                               #help-platform

  The October release label is 2026.10.2. It is in values-staging.yaml on
  main, the helm-drill-82 job built it and went GREEN (Deploy, Test, all of
  it), and `helm list` says revision 3 is "deployed".

  But the running staging service still says the old one:

    curl http://demo-api/        ->  {"app":"demo-api","version":"2026.10.1"}

  and kubectl shows the pods are 40 minutes old. The ConfigMap does say
  2026.10.2, I looked. Sign-off needs the endpoint to show the new label.
  If somebody tells me to "just delete the pods", fine, but then why did
  the pipeline say green, and will it happen again on the next release?

  Namespace helm-drill-82, release "demo-api", repo payments/helm-drill-82
  (a clone is in ~/platform-playground/helm-drill-82).
