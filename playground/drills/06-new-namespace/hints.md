Read the forbidden message word for word: WHO (which user / service
account) cannot do WHAT (verb, resource) WHERE (namespace)? Then ask the
cluster the same question:
  kubectl --context kind-playground auth can-i create deployments \
    -n payments-staging --as=system:serviceaccount:jenkins:jenkins-agent
---
Look at how demo-ci is granted: ~/gcp/platform-lab/ci/jenkins/rbac.yaml.
A Namespace, a Role and a RoleBinding for payments-staging, in the same
shape, is least privilege. cluster-admin is the check's instant fail.
---
Once RBAC is right, the deploy fails AGAIN, differently. The Service in
k8s/deployment.yaml hard-codes nodePort: 30095, and a NodePort is
cluster-wide: demo-ci already holds it. Should two environments share one
fixed port? (Hint: they should not.)
