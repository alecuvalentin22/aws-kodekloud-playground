ROOT CAUSE
  The Deployment's pod template lost its  checksum/config  annotation (commit
  "deployment: drop checksum/config (staging restarted on every config tweak,
  noisy diffs)"). The app reads VERSION from the environment when it STARTS, and
  the chart injects it with  envFrom: configMapRef. Kubernetes restarts pods only
  when the POD TEMPLATE changes. A ConfigMap edit changes the ConfigMap object and
  nothing in the template, so:

    helm upgrade   -> ConfigMap now says 2026.10.2        (true, "deployed")
    Deployment     -> template identical, no new ReplicaSet, no new pods
    pods           -> still carry the env they started with (2026.10.1)

  Nothing failed, so nothing was red: helm did exactly what it was told. The only
  wrong thing was the assumption "config change = restart". (Why a values-only
  helm upgrade and not the Jenkins job? Jenkinsfile.helm packages every build as
  0.1.0-build.N and helm.sh/chart is a pod label, so a pipeline deploy changes the
  template and rolls the pods whatever the config did. The bug shows on deploys that
  keep the chart version: helm upgrade by hand, Argo CD, a values-only rerun.) Env vars from
  a ConfigMap are never refreshed in a running container (files mounted from a
  ConfigMap volume are eventually refreshed, but the app would still have to re-read
  them).

HOW TO SEE IT
  kubectl -n helm-drill-82 get cm demo-api -o jsonpath='{.data.VERSION}'            # 2026.10.2
  kubectl -n helm-drill-82 exec deploy/demo-api -- printenv VERSION                 # 2026.10.1
  kubectl -n helm-drill-82 get pods                                                 # AGE older than the deploy
  kubectl -n helm-drill-82 rollout history deploy/demo-api                          # no new revision for the last deploy
  helm -n helm-drill-82 get manifest demo-api | grep -c checksum                    # 0
  git -C ~/platform-playground/helm-drill-82 log -p -- chart/demo-api/templates/deployment.yaml
  helm -n helm-drill-82 history demo-api                                            # rev 3 "deployed", chart not bumped

FIX
  Restore the annotation in templates/deployment.yaml (spec.template.metadata.annotations):

      checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}

  It hashes the rendered ConfigMap, so ANY config change becomes a template change,
  hence a rolling update; an upgrade with the same config renders the same hash and
  restarts nothing. Bump the chart version (0.1.1), push, run the helm-drill-82 job.
  This upgrade adds the annotation, so the template differs from what runs and the
  pods roll once (maxUnavailable 0: no downtime) onto 2026.10.2.
  The check then changes the config once more through Helm and expects the pods to
  roll on their own, and puts it back with helm rollback.

NOT ACCEPTABLE
  - kubectl rollout restart / delete pods and call it done. It shows the right
    label today (and adds a kubectl.kubernetes.io/restartedAt annotation Helm does
    not own) but the next config change is silent again. Without the checksum
    annotation the check fails; with it, a restart you did on the way is not held
    against you.
  - A random or time-based annotation (randAlphaNum, now, uuidv4) so "every upgrade
    restarts": config changes roll, but so does every image-only or no-op upgrade
    (PENALTY 15). Pods restarting when nothing changed is its own incident.
  - Putting the config in the image or in an Argo/Helm hook to dodge the problem.

VARIANTS WORTH KNOWING
  - Stakater Reloader / reloader.stakater.com annotations: a controller restarts the
    workload when the ConfigMap changes. Fine, but it is another thing to run and
    it acts outside Helm's release record.
  - Mount the ConfigMap as a volume and have the app reload on file change: no restart,
    but the app has to support it; subPath mounts are never refreshed.
  - Secrets need the same hash trick; the hash must come from the rendered Secret
    template, not from a value that might be a reference to it.
  - Argo CD renders with helm template and applies, so the same annotation is what
    rolls pods there too.

WHAT STOPS IT RECURRING
  - Keep the checksum annotation next to a comment that says WHY (it had one, and
    it was deleted with the annotation). Review a template diff by asking what
    behaviour it removes, not whether it looks tidier.
  - A pipeline smoke test that asks the RUNNING service for the thing that just
    changed (the label, a flag), not just "is it healthy".
  - A chart test (helm unittest, or the check's own trick): render twice with a
    different config value and assert the pod template differs.

SAY THIS IN THE INTERVIEW
  "The ConfigMap had the new value and the pods did not, because env from a
  ConfigMap is read when the container starts and Kubernetes only restarts pods
  when the pod template changes. Somebody had removed the checksum/config
  annotation from the Deployment, which is the thing that makes a config change a
  template change. helm said deployed because nothing failed; it just did not roll
  anything. I put the annotation back, hashed from the rendered ConfigMap,
  bumped the chart version and deployed it. I did not just restart
  the pods, because that fixes today's label and leaves the next config change
  silent, and I did not use a random annotation, which restarts everything on
  every upgrade. Then I changed the config again to prove the pods roll by
  themselves."

  Related: drill 02 (rollouts), drill 83 (a green pipeline over a bad release),
  the demo-api chart README ("checksum annotation").
