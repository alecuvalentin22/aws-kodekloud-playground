ROOT CAUSE
  Every GitHub Actions run gets a GITHUB_TOKEN, and what it may do is set by
  `permissions:`. This workflow sets `contents: read` at the top (good: read-only by
  default). The publish job used to carry its own `permissions:` block with
  `packages: write`; a teammate removed it as "redundant". Without it the job
  inherits the workflow's `contents: read` only, so `docker login ghcr.io` with the
  token works (anyone can authenticate) but the push is refused: no `packages`
  permission. A job-level `permissions:` block replaces the workflow-level one; it
  does not add to it, which is why the job block also repeats `contents: read`.

FIX
  Least privilege at JOB level, on the one job that pushes:
      publish:
        permissions:
          contents: read
          packages: write
  Via a pull request, then the merge to main publishes ghcr.io/<you>/playground-demo-api:sha-<7>.
  NOT: `permissions: write-all`, NOT `packages: write` at the workflow level (the lint
  call, the tests and any step added later all get to write packages), NOT changing the
  repository's default workflow permissions to read-and-write (the explicit YAML wins
  over that setting here, and widening it makes every future workflow over-privileged).

WHAT STOPS IT RECURRING
  A comment next to the block saying WHY it exists; CODEOWNERS on .github/workflows/;
  a PR check that fails when a job pushes to a registry without the permission
  (actionlint/zizmor catch missing and excessive permissions); for production, publish
  with OIDC to a cloud registry or with a scoped token, and keep the default read-only.

SAY THIS IN THE INTERVIEW
  "A 403 on a registry push with an authenticated login means the identity is fine and
  the grant is missing. The job log lists the GITHUB_TOKEN permissions per job: only
  contents: read. Someone had removed the job-level block as redundant. I put
  packages: write back on the publish job alone, in a PR, and left the workflow default
  at read-only, so lint, tests and any future job can't publish. Granting write-all to
  make the error go away would also have worked, and is the answer that gets a pipeline
  compromised."
