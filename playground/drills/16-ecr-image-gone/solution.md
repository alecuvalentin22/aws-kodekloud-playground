ROOT CAUSE
  A lifecycle policy added "to save storage" expires every image older than a
  day: tagStatus "any" + countType "sinceImagePushed" (countUnit days, 1).
  ECR does not care what is deployed. The tag prod runs was pushed more than a
  day ago, so the policy deleted it from the registry. Running pods are fine
  because they pulled it long ago (and the node caches it); any NEW pod -- a
  scale-up, a reschedule, a node replacement, a rollback -- asks the registry and
  gets "not found":
    Failed to pull image "<acct>.dkr.ecr.us-east-1.amazonaws.com/platform-lab/demo-api:main-<sha>-<n>":
    ... not found     ->  ErrImagePull -> ImagePullBackOff
  The incident is hours or days after the change, which is why nobody connects
  them.

FIX (two jobs)
  1. Get the image back. Rebuild main (Jenkins Build Now or a commit): the
     pipeline pushes a NEW tag and deploys it, the stuck rollout completes.
     (Re-pushing the SAME tag would need the image bytes; with the tag expired
     and no other tag on the digest, there is nothing to re-tag from. If a
     digest had survived: aws ecr batch-get-image --image-ids imageDigest=...
     then put-image with the same manifest and the old --image-tag.)
  2. Make the policy safe, do not delete it (the cloud team's cost worry is real):
       rule 1: tagStatus tagged, tagPrefixList ["main-"], countType
               imageCountMoreThan, countNumber 10  -> keep the newest 10 builds
       rule 2: tagStatus untagged, countType sinceImagePushed, days 1
               -> untagged layers from interrupted pushes go after a day
     How ECR reads it:
       - rules run in rulePriority order, and an image is acted on by the FIRST
         rule that selects it. tagStatus "any" has to be the LAST (highest number).
       - tagStatus: any = everything, untagged = no tag, tagged = needs
         tagPrefixList (startswith) or tagPatternList (* wildcards).
       - sinceImagePushed = age. It expires anything old enough, including what
         prod still runs. Wrong tool for tags that are deployed.
       - imageCountMoreThan = count. Keep the newest N of the images this rule
         selects. Safe for deployed tags as long as N covers the running image
         AND the one a rollback returns to (revisionHistoryLimit here is 5).
     Preview before saving: aws ecr start-lifecycle-policy-preview, then
     get-lifecycle-policy-preview lists what WOULD be deleted. check.sh does the
     same reasoning in jq (lifecycle.jq) against the deployed tag and against a
     future main-* tag.
  NOT: deleting the policy (PENALTY: storage is unbounded again), or only
  protecting today's tag by listing it in a prefix rule (the next build's tag is
  unprotected; the check tries a future tag too).

HOW THIS DRILL MADE THE FAILURE (honest version)
  ECR evaluates lifecycle policies asynchronously, up to about 24 hours after
  they are saved, and a one-day age rule would not touch an image pushed minutes
  ago anyway. break.sh therefore saves the policy AND deletes the images itself
  with batch-delete-image, "simulating the policy's run" a day later. It also
  sets imagePullPolicy: Always on the Deployment: the nodes still cache the image,
  and a new pod would start from the cache and hide the problem; Always makes
  every new pod behave like one on a fresh node. Then it deletes one pod, so its
  replacement lands in ImagePullBackOff while the other pod keeps serving.
  The check uses the same idea: a probe pod with imagePullPolicy Always.

WHAT STOPS IT RECURRING
  Lifecycle policies as reviewed code (Terraform), with a rule for every tag
  prefix that gets deployed; a canary that pulls what prod runs; deploy by digest
  or keep-last-N per prefix; an alert on ImagePullBackOff / FailedPull events.

SAY THIS IN THE INTERVIEW
  "One pod fine, one in ImagePullBackOff with the same tag: the difference is
  that one pulled yesterday and one is pulling now, so I asked ECR whether the
  tag still existed. It didn't -- a lifecycle policy added for storage costs
  expired everything older than a day, including what prod runs. I rebuilt
  through the pipeline to put an image back, then rewrote the policy instead of
  deleting it: count-based rules per tag prefix, keeping the last N builds so
  the running image and its rollback target are always inside the window, and
  untagged cleanup by age. The lesson is that an age rule and a deployed tag are
  in conflict, and the damage shows up a day after the change."
