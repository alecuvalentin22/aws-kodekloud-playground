From: Dana (web team)                                        #help-platform

  our asset publish broke when we moved to the new bucket. the old bucket
  worked fine for years, same script, nothing changed on our side:
    ./publish.sh
  fails with an error about ACLs (see below, I pasted what I saw). the new
  bucket was created by the platform team's template, so I assume it is
  "configured wrong" -- can someone fix the bucket so the script works again?
  ps: the script comes from the 2019 "publishing static assets" wiki page,
  it has always worked.
  it's in ~/platform-playground-aws/drill75 (creds: . ./aws-env.sh;
  the bucket name is in publisher.env)

From: Security team                                          #platform-changes

  Reminder: the assets bucket is NOT public. The site serves assets through
  signed URLs / the CDN, never straight from S3. No public buckets, please.
