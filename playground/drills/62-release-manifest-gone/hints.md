Start with the bucket, not with a laptop. What does S3 hold for these two keys
right now, and what did it hold an hour ago?
  aws s3api list-object-versions --bucket <bucket> --prefix releases/
Read it: which entries are Versions, which are DeleteMarkers, which one is
IsLatest, and what are the timestamps? Is the bucket versioned at all?
---
notes.md: a plain "delete" on a versioned bucket does not remove anything, it
stacks a DeleteMarker on top. Two ways back: delete the marker itself (call
delete-object WITH its --version-id), or copy the last real version over the top.
manifest.json: three versions, three different contents. Look at each with
`aws s3api get-object --bucket B --key releases/manifest.json --version-id V /dev/stdout`.
Which one is the release Sam said was good on Friday? Not the oldest, and not
the one the script wrote.
---
Restore forward and keep the history: a server-side copy of the good version
on top of the current one makes it the new latest version without touching
the others:
  aws s3api copy-object --bucket B --key releases/manifest.json \
    --copy-source "B/releases/manifest.json?versionId=<good>"
For notes.md either that or `aws s3api delete-object --bucket B --key
releases/notes.md --version-id <the delete marker's id>`.
Do not suspend versioning, do not delete versions to "get back" to a state, and
think about what an upload from a laptop file loses compared with a copy of
the version (look at `head-object`: Metadata).
