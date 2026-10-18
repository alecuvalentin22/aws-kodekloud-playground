From: Dana (checkout team)                                    #help-platform

  We moved checkout onto the platform's demo-api chart (namespace
  helm-drill-81, release "checkout") and the pods look perfect:

    kubectl -n helm-drill-81 get pods      ->  2 pods, Running, 1/1 Ready, 0 restarts

  But nothing can reach it. Anything that calls  http://checkout-demo-api
  gets "connection refused", and the pipeline's last stage ("Test", the helm
  test) is red. The app logs are clean; the pods are fine. It worked in the
  first deploy last week.

  Please don't give me a port-forward or a pod IP to hard-code, the callers
  need the Service name. Job: helm-drill-81 in Jenkins. The repo is
  payments/helm-drill-81 (a clone is in ~/platform-playground/helm-drill-81).
