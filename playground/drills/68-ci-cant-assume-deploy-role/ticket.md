From: Radu (CI / release engineering)                        #help-platform

  the nightly deploy job has been red since this morning. our deploy
  step assumes the CI role, then the deploy role, then lists the release
  bucket. now it dies on the second assume-role:
    An error occurred (AccessDenied) when calling the AssumeRole operation:
    User: arn:aws:sts::<acct>:assumed-role/platform-lab-drill68-ci/ci-deploy
    is not authorized to perform: sts:AssumeRole on resource:
    arn:aws:iam::<acct>:role/platform-lab-drill68-deploy
  nothing changed in our scripts. the CI role works (the first hop is
  fine). I haven't touched either role.
  script: ~/platform-playground-aws/drill68/deploy.sh   (creds: . ./aws-env.sh)

From: Security team                                          #platform-changes

  SEC-341 (merged yesterday): the deploy role's trust policy now names a
  principal and requires an ExternalId, per our standard for CI systems
  that live outside AWS:
      sts:ExternalId = plt-ci-7f3a91
  Reviewed by two people. No action needed from teams.
