ROOT CAUSE (two of them, in sequence)
  1. The agent's service account is bound to a Role in demo-ci only. In
     payments-staging it has no rights, so the API returns 403 forbidden.
     (And the namespace does not exist yet.)
  2. With RBAC fixed, the Service fails. Verbatim:
       The Service "demo-api" is invalid: spec.ports[0].nodePort: Invalid
       value: 30095: provided port is already allocated
     nodePort 30095 is a CLUSTER-wide resource already used by demo-ci.
     Note the half-state: kubectl applied the Deployment BEFORE the Service
     failed, so payments-staging runs 2/2 pods while the build is red. "Red"
     does not mean "nothing changed" -- check what actually landed.

FIX
  - Namespace payments-staging + Role (deployments/replicasets/services/pods/
    configmaps get/list/watch/create/update/patch, events read) + RoleBinding
    to jenkins:jenkins-agent. Same shape as ci/jenkins/rbac.yaml. Kept in git.
  - Stop hard-coding the nodePort (let Kubernetes allocate one, or use
    ClusterIP + an Ingress per environment).
  NOT acceptable: cluster-admin. A pipeline runs code from any branch of any
  repo Jenkins builds; whatever the agent can do, every branch can do.

SAY THIS IN THE INTERVIEW
  "I gave the pipeline exactly one more namespace, with a Role and RoleBinding
  rather than cluster-admin, and verified it with `kubectl auth can-i --as` the
  service account -- both that it can deploy to staging and that it still can't
  touch kube-system. Then the deploy failed again on a NodePort clash, because
  a NodePort is cluster-scoped; we'd hard-coded it per service, not per
  environment. That's the second bug the first one was hiding."

  On EKS, the same reasoning extends to AWS: IRSA / Pod Identity scope the
  agent's AWS rights per service account (platform-lab drills/18 section 2).
