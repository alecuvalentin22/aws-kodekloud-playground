#!/usr/bin/env bash
# Fixed means: the repository is STILL immutable, 1.4.0 is still the image prod
# runs (same digest, same push time), a NEW tag (not `latest`) exists with a
# different digest pushed after the drill started, and release.sh -- as the
# candidate left it -- no longer targets 1.4.0 (`./release.sh --dry-run` prints
# the tag it would push).
# If the repository is found MUTABLE, the check puts IMMUTABLE back (so the fix
# is judged against the real baseline) and remembers it across checks: PENALTY 50.
# If 1.4.0 is gone or no longer the recorded digest/push time: PENALTY 30 (the
# check cannot undo that; it is the other half of the damage).
# AWS API calls: ecr DescribeRepositories, DescribeImages (read),
# PutImageTagMutability (only to put IMMUTABLE back).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
REC="$STATE/drill65.env"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
REPO=""; DIR=""; ORIG_DIGEST=""; ORIG_PUSHED=""
# shellcheck disable=SC1090
source "$REC"
FLAG="$STATE/drill65.mutable-seen"

mut=$(aws ecr describe-repositories --repository-names "$REPO" --query 'repositories[0].imageTagMutability' --output text 2>&1) \
  || { c_bad "cannot read repository $REPO: ${mut:0:200}"; exit 1; }

# 1. Still immutable? Remembered across checks, and put back if needed.
if [[ $mut != IMMUTABLE ]]; then
  date -u +%FT%TZ > "$FLAG"
  c_warn "$REPO is $mut: the security baseline (immutable tags) was switched off. Putting IMMUTABLE back so the fix is judged against it"
  aws ecr put-image-tag-mutability --repository-name "$REPO" --image-tag-mutability IMMUTABLE >/dev/null 2>&1 \
    || { c_bad "could not put the repository back to IMMUTABLE"; exit 1; }
fi
if [[ -f $FLAG ]]; then
  pen50=yes
  c_bad "the repository was MUTABLE at $(cat "$FLAG") (it is IMMUTABLE again now)"
else
  pen50=no
  c_ok "$REPO is still IMMUTABLE"
fi

# 2. Is 1.4.0 still the image prod runs?
pen30=no
cur=$(aws ecr describe-images --repository-name "$REPO" --image-ids imageTag=1.4.0 --output json 2>/dev/null \
      | jq -c '.imageDetails[0] // empty')
if [[ -z $cur ]]; then
  pen30=yes; c_bad "tag 1.4.0 is gone from $REPO: what prod runs (digest $ORIG_DIGEST) cannot be pulled by tag any more"
else
  d=$(jq -r .imageDigest <<<"$cur")
  pushed=$(aws ecr describe-images --repository-name "$REPO" --image-ids imageTag=1.4.0 --query 'imageDetails[0].imagePushedAt' --output text)
  if [[ $d != "$ORIG_DIGEST" || $pushed != "$ORIG_PUSHED" ]]; then
    pen30=yes; c_bad "tag 1.4.0 no longer points at the image prod runs ($d, was $ORIG_DIGEST): it was deleted and pushed again"
  else
    c_ok "1.4.0 still points at the original digest ${ORIG_DIGEST:0:19}..."
  fi
fi

# 3. A new tag with a different digest, pushed after the drill started.
all=$(aws ecr describe-images --repository-name "$REPO" --output json | jq -c '.imageDetails')
newtags=$(jq -r --arg od "$ORIG_DIGEST" '[.[] | select(.imageDigest != $od) | (.imageTags // [])[]
            | select(. != "1.4.0" and . != "latest")] | join(" ")' <<<"$all")
hadlatest=$(jq -r --arg od "$ORIG_DIGEST" '[.[] | select(.imageDigest != $od) | (.imageTags // [])[] | select(. == "latest")] | length' <<<"$all")
fail=0
if [[ -n $newtags ]]; then
  c_ok "the hotfix is in the registry under a new tag: $newtags"
else
  if (( hadlatest )); then
    c_bad "the hotfix is only tagged \`latest\`: a moving name is not a release version (and it will not be pushable twice in an immutable repo either). Use a unique tag"
  else
    c_bad "no new tag in $REPO: the hotfix image is not in the registry yet"
  fi
  fail=1
fi

# 4. What would the NEXT run of release.sh push?
if [[ ! -f $DIR/release.sh ]]; then c_bad "$DIR/release.sh is gone"; exit 1; fi
dry=$(cd "$DIR" && bash ./release.sh --dry-run 2>&1); drc=$?
if (( drc != 0 )); then
  c_bad "release.sh --dry-run fails (keep that option, the check uses it): $(tail -n 2 <<<"$dry" | tr '\n' ' ' | cut -c1-200)"; fail=1
else
  nexttag=$(grep -Eo '[^/ ]+:[A-Za-z0-9_.-]+$' <<<"$dry" | tail -n 1 | sed 's/^[^:]*://')
  if [[ -z $nexttag ]]; then
    c_bad "release.sh --dry-run did not print an image reference (registry/repo:tag): $(cut -c1-160 <<<"$dry")"; fail=1
  elif [[ $nexttag == 1.4.0 ]]; then
    c_bad "release.sh still tags the image 1.4.0: the next hotfix will fail the same way"; fail=1
  elif [[ $nexttag == latest ]]; then
    c_bad "release.sh now pushes \`latest\`: the second hotfix fails the same way, and a mutable name defeats the point"; fail=1
  else
    c_ok "release.sh would push $nexttag, not 1.4.0"
  fi
fi

if [[ $pen50 == yes ]]; then
  echo "PENALTY 50 The repository's immutability was switched off. Immutable tags are the platform team's supply-chain guardrail (what you tested is what runs); the fix is a unique tag per build, not removing the guardrail."
fi
if [[ $pen30 == yes ]]; then
  echo "PENALTY 30 1.4.0 was deleted and/or re-pushed. Whatever pulled 1.4.0 before is not what pulls it now, and nothing records that; a hotfix is a new version, not an edit of an old one."
fi
(( fail )) && exit 1
exit 0
