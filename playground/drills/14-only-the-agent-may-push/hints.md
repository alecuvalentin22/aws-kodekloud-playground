Start by confirming the finding yourself, not by taking it on trust:
  kubectl --kubeconfig ~/.kube/andrei-lab-eks -n sandbox logs curious-intern
WHICH principal is it pushing as, and why does a pod in `sandbox` get it?
(Where do pod credentials come from when nothing assigns any?)
Lab credentials for the aws CLI: set -a; . ~/.config/platform-lab/aws-lab-creds.env; set +a
---
Two ways to give one service account its own AWS identity: IRSA (an IAM
OIDC provider for the cluster's issuer + a role whose trust policy pins
`sub` to system:serviceaccount:jenkins:jenkins-agent and `aud` to
sts.amazonaws.com) or EKS Pod Identity (the pod-identity agent add-on + an
association; trust principal pods.eks.amazonaws.com). Try the first step of
either. This is a locked-down playground -- the answer may be AccessDenied,
and it may come at a later step than the first (the role, not the provider).
---
If it is refused: put the exact error in
~/platform-playground-aws/evidence/14-design.md, then the design you would
ship: trust policy, a push policy on the ONE repository ARN, the
service-account annotation (or association), what you take away from the
node role (push -> pull-only), and how you would prove it (the sandbox pod).
