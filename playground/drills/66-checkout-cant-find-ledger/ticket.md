From: Sam (payments)                                          #help-platform

  checkout stopped talking to ledger since the "DNS tuning" PR went out
  this afternoon. The checkout log says:

    ERROR could not reach http://ledger:8080/ -> <urlopen error
    [Errno -2] Name or service not known>

  but ledger is Running, its Service exists, and I can curl it from my
  laptop through a port-forward. Nothing changed in ledger. I only touched
  checkout's DNS settings ("use the node's resolver, faster") -- how can
  that break a Service name?? Rolling back is not an option: that commit
  also carries the payments retry fix.
  namespace: platform-lab-drill66   manifests: ~/platform-playground-aws/drill66
  (git log shows the PR)

From: Platform on-call                                        #platform-changes

  no cluster-side change today; CoreDNS is healthy and every other
  namespace resolves fine.
