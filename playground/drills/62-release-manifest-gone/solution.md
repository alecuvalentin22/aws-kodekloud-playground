ROOT CAUSE
  Nothing was lost. The bucket is versioned, so the nightly "tidy" job did two
  things that look destructive and are not:
    - it OVERWROTE releases/manifest.json: S3 added a third version on top and
      kept the two before it (2026.10.1, and the pipeline's good 2026.10.2);
    - it DELETED releases/notes.md: on a versioned bucket a plain delete only
      stacks a DeleteMarker on top. The text is still there as the version
      underneath; GET without a version id answers 404 because the newest entry
      is the marker.
  "Do we have backups?" -- yes, the bucket's own history. What makes it feel like
  data loss is that every default read (GET, ls, the deploy job) sees only the
  newest entry.

FIX (restore forward, keep the history)
  1. aws s3api list-object-versions --bucket B --prefix releases/
     Versions vs DeleteMarkers, IsLatest, LastModified, VersionId.
  2. notes.md: delete the DELETE MARKER (not the data):
       aws s3api delete-object --bucket B --key releases/notes.md --version-id <marker id>
     (or copy the last real version on top of it).
  3. manifest.json: read each version (get-object --version-id, to /dev/stdout)
     and pick the one that is the last GOOD deploy -- release 2026.10.2, the middle
     one. Not the oldest (Sam's laptop copy from Thursday is that: it parses and
     deploys an OLD release, quietly rolling production back), not the newest
     (the truncated file). Make it current with a server-side copy:
       aws s3api copy-object --bucket B --key releases/manifest.json \
         --copy-source "B/releases/manifest.json?versionId=<good>"
     That creates a NEW version with the good bytes; v1, v2 and the broken v3 all
     stay, so the post-mortem still has the broken file.
  NOT:
    - deleting the broken version (delete-object --version-id) to make the good
      one current: it works, and destroys the evidence and a way back. PENALTY 30.
    - suspending versioning "to clean up": writes then overwrite in place with a
      null version id, and what they overwrite is gone. PENALTY 40.
    - uploading a file from a laptop (Sam's, or a downloaded copy of v2). Wrong
      file if it is Sam's; if it is the right bytes it is still a new, unproven
      object, not the one the pipeline built. PENALTY 15 (see below).

HOW THIS DRILL TELLS A RESTORE FROM A RE-UPLOAD (honest version)
  S3 itself cannot: copy-object leaves no link to its source, and the bytes (so the
  sha256 and the ETag) are the same either way. The only trace is the object's
  metadata. The pipeline wrote every object with user metadata (pipeline, build-id);
  copy-object keeps it (MetadataDirective COPY is the default), while put-object /
  `aws s3 cp` of a local file writes none. The check looks at build-id. It is a
  proxy: a candidate who re-uploads WITH --metadata build-id=2417 defeats it, and
  that is acceptable -- the point of the penalty is the habit, and in real life the
  same metadata/tags/content-type are exactly what a laptop copy drops.
  Versioning suspended is seen two ways: check.sh notices status Suspended while
  the incident is open (remembers it), and any "null" version id in the listing.

WHAT STOPS IT RECURRING
  Least privilege: the tidy job should not have s3:PutObject on releases/ nor
  s3:DeleteObject at all (and nobody but break-glass has s3:DeleteObjectVersion).
  MFA Delete or Object Lock on the release prefix for what must not change; a
  lifecycle rule that expires NONCURRENT versions after N days (not 1) so history
  is bounded but never zero; a bucket policy denying DeleteObjectVersion; release
  manifests addressed by immutable keys (releases/2026.10.2/manifest.json) with a
  "current" pointer, so a rewrite never overwrites the only copy; replication to a
  second bucket/account for real backups (versioning is not a backup against
  deleting the bucket or the account).

SAY THIS IN THE INTERVIEW
  "Two files, two symptoms, one cause: a tidy job ran against a versioned bucket.
  I did not reach for a laptop copy. I listed the object versions: the manifest
  had three, the newest was truncated, and notes.md had a delete marker on top,
  which is why it 404'd while the data sat underneath. I removed the marker, and
  for the manifest I read the versions and copied the last good release, the
  middle one rather than the oldest, back to the top with a server-side copy,
  which keeps all versions, the broken one too, and keeps the object's metadata.
  The bucket's versioning was the backup; I would not call it a backup strategy.
  Then I took write and delete away from the job, and put a noncurrent-version
  lifecycle rule and a replica behind it."
