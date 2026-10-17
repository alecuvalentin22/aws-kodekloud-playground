ROOT CAUSE
  The repository is IMMUTABLE (platform baseline SEC-402). In an immutable ECR
  repository a tag can be written once; pushing the same tag again, with
  different content, is refused at the moment the manifest is put:
    error from registry: The image tag '1.4.0' already exists in the
    '<repo>' repository and cannot be overwritten because the tag is immutable.
  (From the API: ImageTagAlreadyExistsException. The layers upload fine first;
  only the final "this tag now points at this manifest" step is refused, which
  is why the push output looks like it nearly worked.)
  The team's release.sh uses "hotfix keeps the version" as its convention:
  TAG=$VERSION. That only ever worked because the repository was mutable and a
  tag was just a movable label. It was never safe:
    - 1.4.0 means different bytes on different days, so "we tested 1.4.0" and
      "prod runs 1.4.0" can be two different images;
    - a rollback to 1.4.0 does not go back to the previous image, it goes to
      whatever 1.4.0 is now;
    - scans, approvals, signatures and SBOMs attach to a digest; moving the tag
      makes them describe something that is no longer behind the tag;
    - nodes with the old image cached and nodes that pull fresh run different
      code under the same tag (IfNotPresent vs Always).
  The same holds for `latest`, only worse.

FIX (on the release process, not on the guardrail)
  1. aws ecr describe-repositories --repository-names <repo>   -> IMMUTABLE
     aws ecr describe-images --repository-name <repo> --image-ids imageTag=1.4.0
     (note the digest: it must be the same at the end)
  2. Change release.sh so every build gets a unique tag: bump the version for a
     hotfix (VERSION=1.4.1 in release.env), or VERSION + build id
     ("1.4.0-hotfix.1", "1.4.0-<git sha>", "1.4.0-<CI build number>").
  3. ./release.sh --dry-run prints the new tag (the check reads it), then
     ./release.sh pushes it. Roll it out by tag AND digest: image
     <repo>@sha256:<new digest> is the unambiguous reference.
  NOT: switching the repository to MUTABLE "just for the hotfix" (PENALTY 50,
  even if you switch it back: the check remembers; it is the platform team's
  supply-chain control), nor deleting 1.4.0 and pushing it again (PENALTY 30:
  the same overwrite, and prod may be running it right now).

WHAT STOPS IT RECURRING
  Tag by git sha / build number in CI, never by hand; deploy by digest (or a
  tag that CI proves is unique); immutability on every repository that prod
  pulls from, enforced in Terraform (image_tag_mutability = "IMMUTABLE") and
  by a policy check; never `latest` in a manifest. Lifecycle rules per tag
  prefix (see drill 16) still apply: immutable does not mean kept forever.

HOW THIS DRILL MADE THE FAILURE (honest version)
  break.sh creates ONE ECR repository platform-lab-drill65/payments-api
  (IMMUTABLE, scanOnPush, tagged platform-lab-drill=65), builds a tiny
  busybox-based image and pushes it as 1.4.0 (digest and push time recorded in
  the state dir), then writes ~/platform-playground-aws/drill65 with the
  teammate's release.sh and runs it once so the refusal is real. Docker
  credentials live in a throwaway DOCKER_CONFIG, never in ~/.docker. check.sh
  reads the repository settings, 1.4.0's digest and push time, the tags that
  exist, and runs `release.sh --dry-run` to see the next tag. If it finds the
  repository MUTABLE it puts IMMUTABLE back and remembers (PENALTY 50). reset.sh
  force-deletes only the recorded repository, the workspace and the local images
  tagged with its URI (the public busybox base stays).

SAY THIS IN THE INTERVIEW
  "The push failed with 'tag already exists ... the tag is immutable'. My
  first read was that the team's habit of re-using 1.4.0 for hotfixes was the
  bug, not the repository: a mutable tag means the same version string can
  mean different bytes on different days, which breaks rollbacks, scans and
  every 'we tested this' claim. So I did not make the repo mutable, which is
  what was asked for. I checked 1.4.0's digest, changed the release script to
  produce a unique tag per build -- the version plus a build id -- pushed
  that, and confirmed the old digest was untouched. I'd also deploy by digest,
  keep immutability on in Terraform, and never use latest."
