Read the failed step's log from the top, not the bottom. The "Set up job" step lists
the permissions GITHUB_TOKEN actually got for THIS job. What does a push to a registry
need that it doesn't list? And what did the workflow file say last week?
  git -C ~/platform-playground-github/playground-demo-api pull && git log -p -3 -- .github/workflows/ci.yml
---
A job gets the permissions of the `permissions:` block at the top of the workflow
unless the job has its own block, which REPLACES (not extends) the workflow's. Where
should `packages: write` live, given that only one job ever pushes an image?
---
Put the permissions on the publish job only:
    permissions:
      contents: read
      packages: write
Do it in a PR, merge it, and let the push run on main publish an image tagged
sha-<7 chars of the merge commit>. Not acceptable: `permissions: write-all`,
`packages: write` at the top of the workflow (every job, including the reusable lint
and the test job, would get it), or flipping the repository's default workflow
permissions to read-and-write (the check looks at all three).
