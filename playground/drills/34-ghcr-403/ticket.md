#help-platform

  Sam (payments):  The publish job on playground-demo-api main went red. Build
                   and tests are fine, then "docker push" fails:
                       denied: permission_denied: The token provided does not
                       match expected scopes.
                   Further up the log, under "GITHUB_TOKEN Permissions", I only
                   see Contents: read and Metadata: read. It pushed fine last
                   week and I never touched the workflow. Did GHCR change?
  Your lead (DM):  Jordan said something about "tightening permissions" in CI.
                   Find out, fix it, and do not give the whole pipeline more
                   access than it needs: security is watching this one.

  Your clone is in ~/platform-playground-github/playground-demo-api. main takes
  pull requests only.
