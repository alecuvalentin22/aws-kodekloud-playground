ROOT CAUSE
  Nothing gives pods an identity, so every pod falls back to the node's
  instance profile through IMDS -- eksWorkerNodeRole. The lab attaches ECR
  PowerUser to that role so the Jenkins agent can push (scripts/jenkins-install.sh
  says so: "Every pod on the node inherits this, which is the honest caveat;
  IRSA/Pod Identity is the production answer"). So the sandbox pod can push too.

FIX (production)
  IRSA:
    1. IAM OIDC provider for the cluster's issuer (aud sts.amazonaws.com).
    2. Role `ci-agent-ecr-push`, trust: Federated = that provider,
       Action sts:AssumeRoleWithWebIdentity, Condition StringEquals
         <issuer>:sub = system:serviceaccount:jenkins:jenkins-agent
         <issuer>:aud = sts.amazonaws.com
    3. Policy: ecr:GetAuthorizationToken on *, and the push actions
       (BatchCheckLayerAvailability, InitiateLayerUpload, UploadLayerPart,
       CompleteLayerUpload, PutImage, BatchGetImage) on
       arn:aws:ecr:us-east-1:<acct>:repository/platform-lab/demo-api only.
    4. Annotate the SA: eks.amazonaws.com/role-arn: <role arn>.
    5. Detach PowerUser from the node role. ECR ReadOnly stays (terraform/eks
       attaches it, nodes still pull; check with list-attached-role-policies).
    6. Prove it: the sandbox pod's initiate-layer-upload is now AccessDenied
       (a token alone is not push: ReadOnly mints tokens too); the pipeline
       still pushes.
  Pod Identity is the same shape with an add-on + association instead of the
  OIDC provider, trust principal pods.eks.amazonaws.com. Also worth naming:
  IMDS hop limit 1 stops pods reaching the node role at all.

THE PLAYGROUND PART
  terraform/eks/variables.tf records that the boundary policy permits iam:CreateRole
  only for eksClusterRole, eksWorkerNodeRole and AmazonEKSFargatePodExecutionRole.
  So even if the OIDC provider can be created, the dedicated role (ci-agent-ecr-push)
  may be what is refused. Either denial is valid evidence. Not yet re-probed on
  the current account.
  A read of this account's AWS_EKSECSWithConditions policy (2026-10-16) did
  not grant iam:CreateOpenIDConnectProvider or eks:CreatePodIdentityAssociation.
  Other attached policies could not be listed, so the live attempt is the real
  answer -- which is why the drill asks for its output, not for a guess.

SAY THIS IN THE INTERVIEW
  "On EKS, a pod with no identity of its own gets the node's. So 'the agent
  can push' really meant 'everything on that node can push'. The fix is to
  give the agent's service account its own role -- IRSA, trust pinned to that
  one service account and audience -- scope push to the one repository, and
  take push off the node role. In the lab account I couldn't create the OIDC
  provider; I captured the AccessDenied and shipped the design for a real
  account, with the test that proves it: the pentester's pod stops working."

  Background: platform-lab drills/18 section 2 ("Production answer"),
  docs/ci-track.md "How does the pipeline authenticate to ECR?".
