Read the WHOLE error: who is the caller (the assumed-role ARN of the CI role,
not the lab user), what is the action (sts:AssumeRole) and on which resource.
Then look at the other side: `aws iam get-role --role-name
platform-lab-drill68-deploy --query Role.AssumeRolePolicyDocument`. A role
assumption is allowed when the TRUST policy of the target role allows it.
---
Two things in a trust policy have to match the request: the Principal (who is
asking) and the Condition (what the request carries). The error text is the
same for a wrong Principal and for a missing condition, so check both: does
Principal name the identity that actually calls AssumeRole? And what does
Condition ask for that deploy.sh does not send? (`aws sts assume-role help`.)
---
Fix both halves. A role's trust policy is set when you create it; on this account
`aws iam update-assume-role-policy` is denied, so recreate the deploy role: delete
platform-lab-drill68-deploy and create it again with the same name and a trust whose
Principal.AWS is the CI role ARN (arn:aws:iam::<acct>:role/platform-lab-drill68-ci), keeping
Action sts:AssumeRole and the ExternalId condition. (The bucket already allows
that role name; nothing else needs granting.) In deploy.sh, add `--external-id
plt-ci-7f3a91` to the SECOND assume-role call only. Do not widen the trust to the account
or "*", do not drop the condition, and do not give the CI role permissions to skip the deploy role.
