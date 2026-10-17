From: Sam (payments)                                          #help-platform

  checkout can't reach ledger since we moved ledger onto the shared Helm
  chart conventions this afternoon. The checkout log says:

    ERROR could not reach http://ledger:8080/ -> <urlopen error
    [Errno 111] Connection refused>

  but both ledger pods are Running and 1/1 Ready, the Service still
  exists, and nothing else changed -- same port, same image, DNS resolves
  `ledger` fine. The only thing we did was relabel the pods
  (app.kubernetes.io/*) the way the chart wants. I don't see why that
  would matter. Rolling back is not an option: the chart migration is
  going out to every service this week.
  namespace: platform-lab-drill74   manifests: ~/platform-playground-aws/drill74
  (git log shows the PR)

From: Platform on-call                                        #platform-changes

  no cluster-side change today; kube-proxy and CoreDNS are healthy and
  every other namespace is fine.
