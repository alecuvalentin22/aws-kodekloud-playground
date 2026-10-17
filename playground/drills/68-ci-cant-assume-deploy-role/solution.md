ROOT CAUSE
  The deploy role's TRUST policy (SEC-341) no longer matched the request, in two
  independent ways, and AWS reports both with the same words:
    An error occurred (AccessDenied) when calling the AssumeRole operation:
    User: arn:aws:sts::<acct>:assumed-role/platform-lab-drill68-ci/ci-deploy is not
    authorized to perform: sts:AssumeRole on resource: arn:aws:iam::<acct>:role/platform-lab-drill68-deploy
  1. Principal: the review typed platform-lab-drill68-legacy-ci (a real role nobody
     can assume) instead of platform-lab-drill68-ci. The caller is the CI role, so
     the Principal does not match. (A non-existent principal would have been
     rejected when saving the policy, which is why a typo here is silent: it is a
     valid but wrong role.)
  2. Condition: the trust requires sts:ExternalId = plt-ci-7f3a91, and deploy.sh's
     second assume-role does not send --external-id. Fixing only one still fails.
  The first hop (lab user -> CI role) is fine: that role's trust is unconditioned.

FIX
  1. aws iam get-role --role-name platform-lab-drill68-deploy \
         --query Role.AssumeRolePolicyDocument
  2. Correct the trust: Principal.AWS = arn:aws:iam::<acct>:role/platform-lab-drill68-ci,
     keep Action sts:AssumeRole and Condition StringEquals sts:ExternalId = plt-ci-7f3a91.
     In a normal account that is `aws iam update-assume-role-policy`. On THIS account it
     is denied, so: delete the deploy role (detach policies first; there are none) and
     create it again with the same name and the corrected trust document. The bucket
     policy matches the role by ARN (aws:PrincipalArn), so the recreated role has access
     at once. (In real life recreating a role changes its unique id and breaks anything
     that references it by id: prefer updating the trust when you can.)
  3. deploy.sh: second hop -> assume "$DEPLOY_ROLE_ARN" ci-deploy --external-id plt-ci-7f3a91
  NOT: Principal = the account root or "*" (PENALTY 50: anyone in the account
  could assume the deploy role; same-account trust on :root delegates to IAM
  policies and is exactly what the review removed), removing the ExternalId
  condition (PENALTY 30: the error disappears but the protection against the
  confused-deputy problem goes with it), or attaching permissions to the CI role
  and deploying as the CI role (PENALTY 20 and the check still requires the
  deploy role's ARN: the point is a powerless CI identity that can only reach one
  narrowly-trusted role).

NOTES ON THE MECHANISM
  - Same account + trust naming a specific role ARN: no identity policy is needed on
    the caller; the trust alone allows it. (Cross-account needs both sides.)
  - ExternalId is not a secret key; it is a value the assuming party must present,
    so a third party cannot trick you into assuming a role for them.
  - Session duration: role chaining (role -> role) is capped at 1 hour whatever the
    role's MaxSessionDuration says; a longer --duration-seconds fails validation.
  - For a CI system outside AWS prefer OIDC (AssumeRoleWithWebIdentity, see drill
    19) over long-lived keys; the role-trust reasoning is the same.

HOW THIS DRILL MADE THE FAILURE (honest version)
  break.sh creates three roles (platform-lab-drill68-ci, -legacy-ci, -deploy, all
  tagged platform-lab-drill=68), one tagged bucket with one object, and a bucket
  policy that lets principals with the deploy role's ARN list/get it. It creates NO
  IAM policy: iam:DeletePolicy and PutRolePolicy are denied on this account, so the
  deploy role's access lives in the bucket policy and reset leaves nothing behind
  that it cannot delete (no policy is intentionally left). iam:UpdateAssumeRolePolicy
  is denied as well, which is why the fix is recreating the role. check.sh reads the live trust policy (penalties are remembered
  across checks) and runs deploy.sh itself. reset.sh deletes only the roles and
  bucket recorded in the state dir.

SAY THIS IN THE INTERVIEW
  "CI could not assume the deploy role after a security change. AccessDenied on
  sts:AssumeRole with no more detail, so I looked at the target role's trust
  policy, not at CI permissions. It had two problems the same error covers: the
  principal pointed at a different role than the one CI actually runs as, and it
  required an ExternalId our script did not send. I fixed the trust to name
  exactly the CI role, kept the condition, and added --external-id to the script.
  I never widened the trust to the account or dropped the condition to get green,
  and I did not hand the CI role extra permissions: CI stays powerless and can
  reach exactly one role."
