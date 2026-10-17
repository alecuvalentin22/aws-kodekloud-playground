ROOT CAUSE
  checkout's pod spec says `dnsPolicy: Default` (the "DNS tuning" PR, commit
  "use the node's resolver"). The name is misleading: Default is NOT the default.
  The default is ClusterFirst. With Default the kubelet gives the pod the NODE's
  /etc/resolv.conf -- on EKS the VPC resolver (the .2 address of the VPC CIDR) and
  the search domain ec2.internal -- so `ledger` is asked of Route 53 Resolver, which
  has never heard of a Kubernetes Service. Only CoreDNS knows
  ledger.platform-lab-drill66.svc.cluster.local. The pod can still resolve public
  names and the VPC's own ones, which is why it looks like "DNS works, but not for
  my service". ledger, its Service and CoreDNS were fine all along.

  The error, as the app sees it:
    ERROR could not reach http://ledger:8080/ -> <urlopen error [Errno -2] Name or service not known>
  (glibc's EAI_NONAME text; musl says "Name does not resolve", busybox wget "bad
  address", curl "Could not resolve host").

HOW TO SEE IT
  kubectl -n platform-lab-drill66 exec deploy/checkout -- cat /etc/resolv.conf
    -> nameserver <VPC base +2>, search ec2.internal   (a ClusterFirst pod has
       nameserver = the kube-dns ClusterIP, search platform-lab-drill66.svc.cluster.local
       svc.cluster.local cluster.local ..., options ndots:5)
  kubectl -n platform-lab-drill66 exec deploy/checkout -- getent hosts ledger   # no output, exit 2
  kubectl -n platform-lab-drill66 get deploy checkout -o jsonpath='{.spec.template.spec.dnsPolicy}'
  git -C ~/platform-playground-aws/drill66 log -p     # the PR
  A pod in the same namespace with the default policy resolves it; that comparison
  isolates the pod spec from CoreDNS.

FIX
  Remove `dnsPolicy: Default` (or set `dnsPolicy: ClusterFirst`) in checkout.yaml,
  kubectl apply -f checkout.yaml, and keep the rest of the commit (the retry fix).
  Re-check resolv.conf, `getent hosts ledger`, and the log line going back to OK.

  NOT:
  - the ledger Service ClusterIP (or a pod IP) in env/URL/hostAliases: it works until
    the Service is re-created or the pod restarts, and hides the real fault
    (PENALTY 40). The name is the contract.
  - dnsPolicy None with a dnsConfig that lists the CoreDNS IP, the search domains and
    ndots by hand: it works, but it is brittle -- the kube-dns IP and the cluster
    domain are copied into one Deployment and drift silently (PENALTY 20).

WHEN EACH dnsPolicy IS RIGHT
  ClusterFirst (default)       almost everything: cluster names via CoreDNS, anything
                               else forwarded upstream by CoreDNS.
  ClusterFirstWithHostNet      pods with hostNetwork: true. A host-network pod with the
                               default ClusterFirst silently falls back to Default.
  Default                      pods that must NOT depend on the cluster DNS and never
                               call a Service by name -- CoreDNS itself, node-level
                               agents. Not "faster".
  None + dnsConfig             you own the whole resolv.conf on purpose (custom
                               resolver, split-horizon lab); you take on the drift.
  dnsConfig.options on top of ClusterFirst is the supported tuning knob.

THE "FASTER" PART (ndots:5)
  ClusterFirst pods get `options ndots:5`: a name with fewer than 5 dots is tried
  with every search suffix first, so an external name like api.example.com costs
  several NXDOMAIN queries before the real one. Real cost, but the fix is on top of
  cluster DNS: end the name with a dot (api.example.com.), set
  dnsConfig: {options: [{name: ndots, value: "2"}]} on the pod, use the full
  service name, or run NodeLocal DNSCache. Bypassing cluster DNS to save a hop
  trades a few milliseconds for the loss of every Service name.

WHAT STOPS IT RECURRING
  A review rule: a dnsPolicy other than ClusterFirst needs a reason in the PR; a smoke
  test that calls a Service by name from the changed pod before merge; measure the
  lookup latency before "tuning" it.

HOW THIS DRILL MADE THE FAILURE (honest version)
  break.sh creates namespace platform-lab-drill66 with ledger (python http.server) and
  checkout (python polling loop), proves checkout logs OK, then applies a second
  commit that adds dnsPolicy: Default to checkout. The failure is real: the kubelet
  builds the pod's resolv.conf from the node's. Nothing in kube-system, CoreDNS or
  the nodes is touched. check.sh inspects the live pod (resolv.conf, an exec lookup
  and HTTP 200, the log). reset.sh deletes the namespace and the workspace.

SAY THIS IN THE INTERVIEW
  "checkout could not resolve ledger right after a DNS tuning change. I looked at the
  pod's /etc/resolv.conf instead of CoreDNS: the nameserver was the VPC resolver and
  the search domain ec2.internal, not the kube-dns service IP -- the commit had set
  dnsPolicy: Default, which means 'inherit the node', not 'the default'. Only
  CoreDNS knows Service names, so I set it back to ClusterFirst and kept the rest of
  the commit. I would not hard-code the Service IP, and if the real concern was
  lookup latency, ndots:5 is the cost to look at, via dnsConfig options or
  NodeLocal DNSCache, not bypassing cluster DNS. Host-network pods are the case
  that needs ClusterFirstWithHostNet."
