Read the whole push output: what exactly does the registry refuse, and why?
Then look at the repository's settings, not at the script:
  aws ecr describe-repositories --repository-names platform-lab-drill65/payments-api
(Lab credentials for the aws CLI: . ./aws-env.sh in the workspace.)
What does imageTagMutability say, and what is the tag 1.4.0 pointing at right
now (aws ecr describe-images --repository-name ... --image-ids imageTag=1.4.0)?
---
Dana asked for the repository to be made mutable. Ask who is pulling
payments-api:1.4.0 at this moment, and what it would mean if 1.4.0 pointed at
different bytes tomorrow than it does today: what did anyone test, scan,
approve? Immutability is a guardrail, and the request is "remove the guardrail
for a 5-minute convenience". The script is the thing that is wrong: it assumes
a tag is a name you can move.
---
Leave the repository IMMUTABLE and leave 1.4.0 alone (do not delete it and
push again either: that is the same overwrite with extra steps). A hotfix is a
new release: give each build a unique tag. In release.sh that is one line, for
example a new version (1.4.1) or the version plus a build identifier
("1.4.0-hotfix.1", a git sha, a CI build number). Keep `--dry-run` working: it
must print the tag the next run would push. Run ./release.sh, then compare
describe-images for both tags: the old digest is untouched, the new one is
different. Bonus for the interview: prod should reference the new image by tag
AND digest (repo@sha256:...).
