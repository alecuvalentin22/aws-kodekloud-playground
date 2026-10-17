ROOT CAUSE
  rel-build starts rel-deploy with a parameter named TAG. Last week rel-deploy's
  parameter was renamed IMAGE_TAG. Jenkins DROPS a parameter the downstream
  job does not define, so rel-deploy ran with its own default (empty), and
  Priya's "no tag means re-apply what is running" turned that into a green no-op:

      rel-deploy #2: DEPLOYING kind-registry:5000/platform-lab/demo-api:main-9faec70b-20
      deployment.apps/relsvc unchanged

  The new image was built and pushed all right (rel-build: "pushing manifest
  for ...payments/relsvc:rel-1-9faec70b@sha256:..."), and nothing used it.
  The only trace of the dropped parameter is a line in the CONTROLLER log, not
  in either build console:

      WARNING hudson.model.ParametersAction#filter: Skipped parameter `TAG` as it
      is undefined on `rel-deploy` (#2). Set `-Dhudson.model.ParametersAction.
      keepUndefinedParameters=true` to allow undefined parameters to be injected ...

  (Do NOT "fix" it with that flag: it is the security switch that lets any
  caller inject arbitrary environment variables.) The rel-deploy build's own
  Parameters page is the quick tell: IMAGE_TAG is empty.

FIX
  Pass the exact tag under the name the downstream job declares:
      build job: 'rel-deploy', parameters: [string(name: 'IMAGE_TAG', value: env.IMAGE_TAG)]
  Run rel-build: rel-deploy's Parameters page shows rel-<n>-<sha>, its log
  says DEPLOYING ...relsvc:rel-<n>-<sha>, `kubectl -n rel-demo get deploy relsvc
  -o wide` shows the same tag, and the running pod's imageID digest equals the
  digest the registry holds for that tag (what the check compares).
  (Reverting Priya's rename in rel-deploy also works, but the release job and
  the runbook use IMAGE_TAG now.) The downstream job must have run once with
  the new definition, or the parameter is "undefined" for the first call too
  (drill 47): here Priya's test run already registered it.

WHAT WORKS BUT HURTS
  - Deploying :latest (rel-build pushes `latest` and passes it): the check
    passes and takes 25 points. A moving tag cannot say which build runs, has
    nothing to roll back to (`latest` has already moved), and a pod restarted
    later can pull a different image than its siblings. Tag = the commit (and build), deploy by tag
    or by digest.
  - Running rel-deploy by hand with the right tag: the cluster is right, the
    wiring is still broken. The check wants the deploy that rel-build started.

WHAT STOPS IT RECURRING
  - A deploy job that cannot run without an explicit version. "No tag means
    re-apply what runs" was meant kindly, and it is exactly what made the
    mismatch invisible: with `error('IMAGE_TAG required')` the very first
    run after the rename would have been red.
  - `build job: ..., wait: true` (the default) and `propagate: true` so the
    upstream is only green when the downstream is; with `wait: false` the
    upstream goes green while the deploy fails, or never ran at all.
  - After renaming a parameter, grep for its callers (git grep TAG) and run
    the pipeline end to end once.

SAY THIS IN THE INTERVIEW
  "I followed one build through both jobs. rel-build pushed a new tag, but
  rel-deploy's Parameters page showed an empty IMAGE_TAG: the upstream was
  passing TAG, which the downstream no longer defined, and Jenkins drops
  unknown parameters, logging only in the controller log. The downstream's
  'no tag, re-apply what runs' default made that a green no-op. I passed the
  exact tag by the right name and verified by digest that the pod runs what
  was built. I did not deploy latest: a moving tag hides which build is
  running and cannot be rolled back to. Then I asked for the deploy job to
  refuse to run without a version, so a mismatch is red on the first run."

  Related: drill 47 (parameters only exist after a run), drill 41 (green but
  broken), exercise `exercises/jenkins-job-types` (upstream/downstream).
