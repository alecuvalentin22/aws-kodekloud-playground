Read the error in the pod's log, to the end: `kubectl -n reports logs deploy/reports-api --tail=3`.
Which AWS API call does it name? Is it s3, or something that happens BEFORE s3 is ever called?
(Lab credentials for the aws CLI: set -a; . ~/.config/platform-lab/aws-lab-creds.env; set +a)
---
A pod only gets S3 access if it first BECOMES the role: the EKS webhook gives the pod a
service-account token and sts:AssumeRoleWithWebIdentity swaps it for role credentials.
That call is judged by the role's TRUST policy, not by its permissions policy.
Compare two things: the service account the pod really runs as
(`kubectl -n reports get deploy reports-api -o jsonpath='{.spec.template.spec.serviceAccountName}'`)
and the `sub` condition in `aws iam get-role --role-name drill19-reports-reader`.
---
The token's `sub` is system:serviceaccount:<namespace>:<serviceaccount-name>, and the trust
policy has to match it exactly. Fix ONE side:
  A. point the Deployment back at the service account the trust names (it still exists), or
  B. change the trust to the new service account name. On a normal account that is
     `aws iam update-assume-role-policy`; this sandbox denies it, so you delete and
     recreate the role with the same name (detach its policy first) -- or take A.
Keep the trust pinned to ONE service account and to aud sts.amazonaws.com. A wildcard in
`sub`, or no `sub` at all, lets every service account in the cluster become this role.
Do not touch the node role. Then verify from inside the pod:
`kubectl -n reports exec deploy/reports-api -- aws sts get-caller-identity`
