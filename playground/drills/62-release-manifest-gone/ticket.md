From: Sam (payments team)                                     #help-platform

  deploy-release is failing: it reads releases/manifest.json from the release
  bucket (platform-lab-drill62-...) and dies with a JSON parse error. And
  releases/notes.md, which the deploy also posts to the channel, is just
  gone: 404.

  The nightly "tidy the release bucket" script ran about an hour ago. I think
  it did this. Friday's good deploy was release 2026.10.2.

  I have a manifest.json on my laptop from Thursday, I can just upload that?
  Also, do we have backups somewhere? I thought S3 kept everything.

From: Bot                                                     #deploys

  deploy-release #2418: FAILED  (jq: parse error: Unfinished string at EOF)
  deploy-release #2419: FAILED  (notes.md: NoSuchKey)
