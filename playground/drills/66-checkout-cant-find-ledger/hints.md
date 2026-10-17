Look at what checkout sees, not what you expect it to see:
`kubectl -n platform-lab-drill66 exec deploy/checkout -- cat /etc/resolv.conf`
and `... -- getent hosts ledger`. Compare with what a pod in another namespace
gets. Which nameserver is it using, and which search domains?
---
`kubectl -n platform-lab-drill66 get deploy checkout -o yaml | grep -n dns`, or
`git -C ~/platform-playground-aws/drill66 show HEAD`. A Pod's dnsPolicy decides
how /etc/resolv.conf is built: ClusterFirst (the default) points at the cluster
DNS Service (CoreDNS) and adds the namespace.svc.cluster.local search domains;
Default inherits the NODE's resolv.conf (the VPC resolver). Who knows what
`ledger` means?
---
Put the pod back on cluster DNS (dnsPolicy: ClusterFirst, or delete the field) and
keep the rest of the commit. If lookups really are slow, the knob is
`dnsConfig.options` (ndots), not bypassing CoreDNS. Do not paste the Service
IP anywhere: it is not stable, and the name is the contract.
