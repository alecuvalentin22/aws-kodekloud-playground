ROOT CAUSE
  The cloud team's tidy-up detached AmazonEC2ContainerRegistryPowerUser from
  eksWorkerNodeRole. Login still works -- ecr:GetAuthorizationToken is also in
  the read-only policy nodes need to PULL -- so the step prints "ECR login
  written", and then the push is refused. From the EKS lab write-up
  (drills/18 section 2):
    ECR login written for <acct>.dkr.ecr.us-east-1.amazonaws.com (token not shown)
    #11 ERROR: failed to push ...: denied: User: arn:aws:sts::<acct>:assumed-role/eksWorkerNodeRole/i-08c1...
        is not authorized to perform: ecr:InitiateLayerUpload on resource: arn:aws:ecr:us-east-1:<acct>:repository/platform-lab/demo-api
  403/denied = credentials arrived and were refused (compare drill 11: 401).

FIX
  Restore push for that principal: re-attach PowerUser (baseline), or better,
  an inline policy with the push actions on the ONE repository ARN.
  NOT: AdministratorAccess / PowerUserAccess / ECR FullAccess on the node role.

WHAT STOPS IT RECURRING
  The role's policies in Terraform, not attached by a script, so a tidy-up is
  a reviewed plan that says "detach" out loud. And the real answer: the node
  role should not push at all (drill 14).

SAY THIS IN THE INTERVIEW
  "The error named the principal, the action and the resource, so I didn't
  guess: the node role couldn't ecr:InitiateLayerUpload on our repo. 'Login
  worked' was a red herring, because the pull policy includes the auth token.
  I restored exactly the push actions on that one repository -- and flagged
  that pushing from the node role at all means every pod can push."

  Source: platform-lab drills/18 section 2.
