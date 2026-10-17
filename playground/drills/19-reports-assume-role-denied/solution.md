ROOT CAUSE
  The pod never became the role. IRSA is two checks, and the ticket looked at the
  wrong one:
    1. TRUST policy (who may assume the role): the EKS webhook gives the pod a
       service-account token; sts:AssumeRoleWithWebIdentity swaps it for role
       credentials ONLY IF the token matches the role's trust policy:
           <oidc-host>:sub  = system:serviceaccount:<namespace>:<serviceaccount>
           <oidc-host>:aud  = sts.amazonaws.com
    2. PERMISSIONS policy (what the role may do): s3:GetObject / s3:ListBucket on
       the bucket. Only evaluated for calls made AS the role.
  A teammate "cleaned up" the manifest: the Deployment runs as ServiceAccount
  `reports` instead of `reports-reader`, annotated with the same role. The
  permissions were right all along. The trust still names
  system:serviceaccount:reports:reports-reader, the token says
  system:serviceaccount:reports:reports, so STS refuses before S3 is ever called:
      An error occurred (AccessDenied) when calling the AssumeRoleWithWebIdentity
      operation: Not authorized to perform sts:AssumeRoleWithWebIdentity
  Read the operation in the error. "AccessDenied" from s3 means permissions;
  AccessDenied from AssumeRoleWithWebIdentity means trust (or a wrong role ARN /
  missing OIDC provider). Reading IAM "twice" proved nothing about the trust.

DIAGNOSE (what to say you ran)
  kubectl -n reports logs deploy/reports-api --tail=3           -> the operation named
  kubectl -n reports get deploy reports-api -o jsonpath='{.spec.template.spec.serviceAccountName}'
  aws iam get-role --role-name drill19-reports-reader --query Role.AssumeRolePolicyDocument
      -> sub says reports-reader, the pod runs as reports
  kubectl -n reports rollout history deploy/reports-api         -> the "cleanup" change-cause
  kubectl -n reports exec deploy/reports-api -- env | grep AWS_ -> AWS_ROLE_ARN and
      AWS_WEB_IDENTITY_TOKEN_FILE are injected: the webhook did its job
  (Decode the token's claims to see sub/aud for yourself: the file at
   $AWS_WEB_IDENTITY_TOKEN_FILE is a JWT; the middle part is base64 JSON.)

FIX: change ONE side, keep the trust tight
  A. Point the Deployment back at the service account the trust names:
       kubectl -n reports set serviceaccount deploy/reports-api reports-reader
     (the old ServiceAccount is still there: apply does not prune). Smallest
     change, no IAM write, rolls the pod.
  B. Change the trust to the new name. Normal account:
       aws iam update-assume-role-policy --role-name drill19-reports-reader \
         --policy-document file://trust.json     # sub ...:reports:reports
     This sandbox DENIES iam:UpdateAssumeRolePolicy (probed 2026-10-17), so here:
     detach the policy, delete the role, create it again with the new trust,
     attach the policy again. The role ARN is unchanged, so the annotation still
     matches. No pod restart is needed: the CLI re-assumes on every call.
  Either way the trust stays: ONE StringEquals subject (namespace + name) and
  aud sts.amazonaws.com.
  Verify from inside the pod, not from IAM:
       kubectl -n reports exec deploy/reports-api -- aws sts get-caller-identity
           -> assumed-role/drill19-reports-reader/...
       kubectl -n reports logs deploy/reports-api --tail=1   -> OK read ...

THE SHORTCUTS THAT FAIL THE REVIEW
  - trust `StringLike ...:sub = system:serviceaccount:reports:*` (or dropping the sub
    condition): it works, and now every service account in the namespace (or the
    whole cluster) can become a role that reads the finance bucket. PENALTY 40.
  - granting the bucket to the NODE role: it "fixes" the 403 for every pod on the
    node, and the pod stops being the role at all. PENALTY 30.
  - s3:* on Resource "*" on the role: leave the trust alone and make the permission
    huge. Wrong half of the problem, and wider than the bucket. PENALTY 20.

HOW THIS DRILL MADE THE FAILURE (honest version)
  Nothing is simulated: break.sh creates a tagged bucket (platform-lab-drill=19,
  public access blocked), a managed policy (GetObject + ListBucket on that bucket),
  the role with a sub/aud-pinned trust against the cluster's existing IAM OIDC
  provider, and a Deployment of the aws CLI (alpine/k8s). It proves the baseline
  (log says OK), then applies the "cleanup" manifest. The AssumeRoleWithWebIdentity
  error is the real STS answer. The managed policy cannot be deleted on this sandbox
  (iam:DeletePolicy is denied by the playground, so it is INTENTIONALLY left): reset.sh detaches it and rolls its default version back to a placeholder, break.sh reuses it.

WHAT STOPS IT RECURRING
  - The ServiceAccount name is part of the IAM contract. Put the role and the SA in
    the same change (Terraform/Helm), so renaming one fails review. A rename of an
    SA with an IRSA annotation is an IAM change.
  - Alert on the pod's own symptom: a log/metric for AssumeRoleWithWebIdentity
    failures, and CloudTrail AssumeRoleWithWebIdentity errors by role.
  - Pin the trust to one namespace+name and aud; never StringLike with a bare "*".
    One role per workload, so a pinned sub is the whole story.
  - EKS Pod Identity moves the binding out of the role's trust policy into an
    association (cluster, namespace, SA -> role): renaming the SA breaks the
    association instead. Same lesson, different place to look. (Denied on this
    account: eks:CreatePodIdentityAssociation.)

SAY THIS IN THE INTERVIEW
  "S3 says AccessDenied, but the log names sts:AssumeRoleWithWebIdentity: the pod
  never became the role, so the role's S3 permissions are irrelevant. That call is
  judged by the role's trust policy: the token's sub is
  system:serviceaccount:<ns>:<sa>, and it has to equal the sub condition exactly.
  I compared the service account the pod runs as with the trust and found a
  rename: the deployment ran as `reports`, the trust said `reports-reader`. I fixed
  one side, pointing the deployment back, or updating the trust to the new name,
  and kept the trust pinned to one namespace+name and aud sts.amazonaws.com. I did
  not use a wildcard in sub and I did not grant the bucket to the node role: that
  gives the bucket to every pod. I verified with aws sts get-caller-identity from
  inside the pod, not by re-reading IAM. To stop it recurring I would manage the
  role and the service account in the same change so a rename shows up as an IAM
  change, and alert on AssumeRoleWithWebIdentity failures."
