Look at the failing pod, not the healthy one: `kubectl describe pod` in
demo-ci and read the Events. What exactly does the registry answer? Then ask
the registry the same question the kubelet did:
  aws ecr describe-images --repository-name platform-lab/demo-api
(Lab credentials for the aws CLI: set -a; . ~/.config/platform-lab/aws-lab-creds.env; set +a)
Why is the other pod fine -- when did it pull?
---
Two things changed on the repository, and only one is visible from the
cluster. `aws ecr get-lifecycle-policy --repository-name platform-lab/demo-api`:
read the rule. What does `tagStatus: any` select? What does `sinceImagePushed`
care about -- and does it care what is deployed? Note when ECR applies a policy
(not at save time) and what that means for how long a bad policy looks harmless.
Two jobs: get the image back, and make sure it cannot happen again.
---
Image: the pipeline built it, so the pipeline can rebuild it (Build Now on
demo-api/main, or push a commit) -- the new tag deploys and the stuck rollout
completes. Policy: do not delete it (the storage worry is real). Replace the age
rule with count-based rules per tag prefix: `tagStatus: tagged`, `tagPrefixList:
["main-"]`, `countType: imageCountMoreThan`, `countNumber: N` keeps the newest N and
expires the rest; N has to cover the running image AND the one a rollback goes
back to. Check it before you save it: `aws ecr start-lifecycle-policy-preview`
then `get-lifecycle-policy-preview` (if this account allows it), or read the rules
against the tag yourself.
