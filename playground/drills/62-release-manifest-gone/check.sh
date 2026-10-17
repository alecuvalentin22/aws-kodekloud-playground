#!/usr/bin/env bash
# Fixed means: releases/notes.md is current again and byte-identical to the original,
# releases/manifest.json is current and byte-identical to the GOOD version (the pipeline's
# 2026.10.2, not the older 2026.10.1 and not the tidy job's truncated one), versioning is
# still Enabled, and the history is intact. Penalties (only on a pass):
#   40  versioning was suspended at some point (seen by a check, or a "null" version exists)
#   30  one of the recorded versions was permanently deleted
#   15  content is right but the object lost the metadata a version copy keeps: it was
#       re-uploaded from a local file instead of restored (S3 keeps no link between a copy
#       and its source, the metadata is the only trace -- see solution.md)
# AWS API calls: s3:GetBucketVersioning, ListObjectVersions, GetObject, HeadObject.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
REC="$STATE/drill62.env"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
# shellcheck disable=SC1090
source "$REC"
sha() { if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || { c_bad "the bucket $BUCKET is gone or unreachable"; exit 1; }

# 1. versioning
vs=$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text 2>/dev/null)
if [[ $vs != Enabled ]]; then
  : > "$STATE/drill62.suspended"
  c_bad "versioning on $BUCKET is '${vs:-off}', not Enabled. Turning it off is how you lose the history this incident is about: put it back"
  exit 1
fi
c_ok "versioning is Enabled"

vers=$(aws s3api list-object-versions --bucket "$BUCKET" --output json 2>/dev/null) || { c_bad "cannot list versions of $BUCKET"; exit 1; }

# 2. the current notes.md exists (the newest entry is not a delete marker)
notes_latest=$(jq -r '[(.Versions // [])[] | select(.Key=="releases/notes.md" and .IsLatest)] | length' <<<"$vers")
if (( notes_latest == 0 )); then
  c_bad "releases/notes.md is still deleted: the newest entry for that key is a delete marker (or nothing at all)"; exit 1
fi
aws s3api get-object --bucket "$BUCKET" --key releases/notes.md "$T/notes.md" >/dev/null 2>&1 || { c_bad "cannot read releases/notes.md"; exit 1; }
if [[ $(sha "$T/notes.md") != "$N1_SHA" ]]; then c_bad "releases/notes.md exists but is not the original text (sha256 differs)"; exit 1; fi
c_ok "releases/notes.md is back, identical to the original"

# 3. the current manifest is the good version
aws s3api get-object --bucket "$BUCKET" --key releases/manifest.json "$T/m.json" >/dev/null 2>&1 || { c_bad "cannot read releases/manifest.json"; exit 1; }
msha=$(sha "$T/m.json")
if [[ $msha == "$M3_SHA" ]]; then
  c_bad "releases/manifest.json is still the truncated file the tidy job wrote"; exit 1
elif [[ $msha == "$M1_SHA" ]]; then
  c_bad "releases/manifest.json parses, but it is release $(jq -r .release "$T/m.json"): the OLDEST version. Friday's good deploy was a later one; compare the versions' timestamps and content"; exit 1
elif [[ $msha != "$M2_SHA" ]]; then
  if jq -e . "$T/m.json" >/dev/null 2>&1; then
    c_bad "releases/manifest.json is valid JSON (release $(jq -r '.release // "?"' "$T/m.json")) but is not the file the pipeline wrote for 2026.10.2"
  else
    c_bad "releases/manifest.json is not valid JSON"
  fi
  exit 1
fi
c_ok "releases/manifest.json is release 2026.10.2, identical to the good version"

# 4. history
lost=0
for v in "$M1_VID" "$M2_VID" "$M3_VID" "$N1_VID"; do
  jq -e --arg v "$v" '[(.Versions // [])[] | select(.VersionId==$v)] | length > 0' <<<"$vers" >/dev/null || lost=$((lost + 1))
done
have=$(jq '[(.Versions // [])[]] | length' <<<"$vers")
if (( lost > 0 || have < VERSIONS )); then
  echo "PENALTY 30 $lost of the original versions were permanently deleted. Restoring means adding the good version on top; deleting versions erases the evidence of what the tidy job did and any way back."
else
  c_ok "all original versions are still there ($have versions)"
fi
nulls=$(jq '[(.Versions // [])[] | select(.VersionId=="null")] | length' <<<"$vers")
if [[ -f $STATE/drill62.suspended ]] || (( nulls > 0 )); then
  echo "PENALTY 40 Versioning was suspended at some point during the fix. While it is off, writes overwrite in place and overwritten data is gone for good."
fi

# 5. restored, or re-uploaded?
reup=0
for spec in "releases/manifest.json:$M2_BUILD" "releases/notes.md:$N1_BUILD"; do
  k=${spec%%:*}; b=${spec##*:}
  got=$(aws s3api head-object --bucket "$BUCKET" --key "$k" --query 'Metadata."build-id"' --output text 2>/dev/null)
  [[ $got == "$b" ]] || reup=1
done
(( reup )) && echo "PENALTY 15 The content is right, but the object lost the metadata the pipeline wrote (build-id): it was uploaded again from a local file, not restored from its version. A laptop copy is only as good as the day it was made; a restored version is the object the pipeline built."
exit 0
