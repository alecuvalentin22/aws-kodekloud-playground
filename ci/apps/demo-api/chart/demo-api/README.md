# demo-api: the lab's own app, packaged as a Helm chart

Until now this repo only **consumed** other people's charts (Jenkins, Prometheus,
Artifactory, Plane...). This directory is the other half of Helm: **packaging your
own application** so that anyone can install, configure, upgrade and roll it back
with one command. It is *added alongside* the original deploy path: the default
`Jenkinsfile` still renders `../../k8s/deployment.yaml` and runs `kubectl apply`
(that is what the playground drills use), and `Jenkinsfile.helm` +
`homelab/platform/apps/90-demo-api-helm.yaml` are the opt-in Helm routes.

If you remember one sentence for an interview:

> A chart is a **directory of Go-templated YAML plus a defaults file**. Helm
> renders it with your values, applies the result, and records every install as
> a numbered **release revision** (a Secret in the namespace), which is what makes
> upgrade, history and rollback possible.

```
ci/apps/demo-api/
  Jenkinsfile.helm            opt-in pipeline: lint -> template -> package -> push (OCI) -> upgrade --atomic -> test
  chart/
    ci-rbac.yaml              Role the Jenkins agent needs to run Helm in demo-helm-ci (NOT part of the chart)
    demo-api/                 <- the chart (this directory)
      Chart.yaml              identity + versions
      values.yaml             every knob and its default
      values.schema.json      rejects wrong/misspelled values before anything is applied
      values-staging.yaml     per-environment overrides (used by Argo CD on the home lab)
      values-prod.yaml        production-shaped overrides (lint/render only; not deployed)
      .helmignore             what NOT to put in the package
      templates/
        _helpers.tpl          named snippets: names and labels, written once
        deployment.yaml  service.yaml  configmap.yaml  serviceaccount.yaml
        ingress.yaml  hpa.yaml            (the last two render only when enabled)
        NOTES.txt             printed after install
        tests/test-connection.yaml        `helm test` hook
```

## Try it (needs only `helm`, no cluster)

```sh
cd ci/apps/demo-api/chart
helm lint demo-api                                   # also: -f demo-api/values-staging.yaml / values-prod.yaml
helm template demo-api demo-api -n demo-ci | less    # what would be applied
helm template demo-api demo-api --set replicaCount=two          # REJECTED by the schema
helm template demo-api demo-api -f demo-api/values-prod.yaml    # adds an HPA and an Ingress
helm package demo-api -d /tmp                        # -> /tmp/demo-api-0.1.0.tgz
```

## What every file is, in plain language

**`Chart.yaml`** is the chart's ID card: name, description, `type: application`
(installable; the other type, `library`, only holds helpers other charts import),
and two versions that people constantly mix up:

| | means | changes when | used by |
|---|---|---|---|
| `version: 0.1.0` | the version of **this packaging**: templates, values, schema | you change anything in this directory | the registry tag, `helm upgrade --version`, `helm list`. **SemVer, and must be unique per published chart.** |
| `appVersion: "1.0.0"` | the version of the **software** inside | you want to document which app release this targets | information only (`helm list` prints it). It does **not** pick the image. |

The image that actually runs is `image.repository:image.tag` from the values. The
two move independently: a new image needs **no** new chart version (just a new
tag value), and a new probe in a template needs a new chart `version` but no new
image. CI publishes `0.1.0-build.<N>` (a SemVer pre-release) so each build has a
unique, immutable-by-convention tag.

**`values.yaml`** is the chart's public interface: every setting a user may
change, with its default. Templates read it as `.Values.something`. Users
override with `-f file.yaml` (many allowed, last wins) and `--set a.b=c` (wins
over files). Rule of thumb: files for anything that should be reviewed in git,
`--set` for what CI computes at run time (the image tag).

**`values.schema.json`** is a JSON Schema that Helm checks on `lint`, `template`,
`install` and `upgrade`. It buys you *typo protection that fails early*: without
it, `replicaCnt: 3` is silently ignored (you think you scaled, you did not) and
`replicaCount: "two"` produces a Deployment the API server rejects halfway
through an upgrade. With it the command stops before touching the cluster:

```
$ helm template x demo-api --set replicaCount=two
- at '/replicaCount': got string, want integer
$ helm template x demo-api --set replicaCnt=3
- at '': additional properties 'replicaCnt' not allowed
$ helm template x demo-api --set image.tag=latest
- at '/image/tag': 'not' failed          # a moving tag makes two deploys differ
$ helm template x demo-api --set image.tag=
- at '/image/tag': '' does not match pattern ...
$ helm template x demo-api --set service.type=NodeProt
- at '/service/type': value must be one of 'ClusterIP', 'NodePort', 'LoadBalancer'
```

`additionalProperties: false` at the top level and inside `image`, `service`,
`ingress`, `autoscaling`... is what catches misspelled keys. It is deliberately
**loose** for `livenessProbe`, `securityContext` and similar pass-through blocks
(Kubernetes validates those itself). The trade-off to mention: a strict schema
must be updated whenever you add a value, or users get "additional property not
allowed" for a legitimate new key.

**`values-staging.yaml` / `values-prod.yaml`** hold only what *differs* from the
defaults: replicas, resources, autoscaling, ingress. Same chart, different file
per environment: that is how Helm avoids copy-pasting manifests per
environment. Staging also pins the image tag, because with GitOps the tag in git
*is* the deployment. They are in `.helmignore` (not part of the package): a
package is environment-agnostic, the environment file is chosen at install time.

**`.helmignore`** is `.gitignore` for `helm package`.

**`templates/_helpers.tpl`**: files beginning with `_` are not rendered as
manifests; they define named snippets (`define "demo-api.fullname"`) that other
templates call with `include`. Why bother:

- **names**: release `demo-api` gives objects called `demo-api`; release `prod` gives `prod-demo-api`.
  Two releases of the chart can coexist in one namespace without colliding.
- **labels**: the standard `app.kubernetes.io/*` set is written once and stamped on every object.
- **selector labels**: written once, so the Deployment's `selector`
  and the Service's `selector` are *the same text by construction*. A Deployment's selector is
  **immutable**, and a Service whose selector does not match the pods has no endpoints
  ("connection refused" with healthy pods; playground drill 74 is exactly this after a Helm
  migration). The selector set is deliberately minimal (name + instance), with no version in it.

**`templates/deployment.yaml`** is the app. Two things to point at:

- **the `checksum/config` annotation** (`include ".../configmap.yaml" . | sha256sum`).
  Kubernetes only restarts pods when the *pod template* changes. A ConfigMap edit changes nothing in the
  template, so without this a `helm upgrade` that changes `config.FAIL_HEALTH` would update the
  ConfigMap and leave the old pods running with the old environment. Putting the ConfigMap's hash into
  the template makes any config change a template change, hence a rolling update.
- **`replicas` is omitted when autoscaling is on**, otherwise every `helm upgrade` would reset
  the HPA's decision back to `replicaCount`.

**`service.yaml`** (ClusterIP by default; the old manifest was a hard-coded NodePort 30095, which
two releases could never share), **`configmap.yaml`** (non-secret settings from `config:`, injected
with `envFrom`; secrets do not belong in values: they end up in release Secrets and in git),
**`serviceaccount.yaml`** (own account, token not mounted: the app never calls the API),
**`ingress.yaml`** and **`hpa.yaml`** (wrapped in `{{- if .Values.<x>.enabled }}`; this is
the standard way a chart offers optional features; prod turns both on).

**`templates/NOTES.txt`** is printed after `helm install/upgrade` (and by `helm get notes`):
the place for "how do I reach it".

**`templates/tests/test-connection.yaml`** is a **hook**: the annotation `helm.sh/hook: test`
keeps the pod out of install/upgrade; `helm test <release>` creates it, waits, and reports its
exit code (the finished pod is left in place so you can read its log; the next run replaces it).
It asks the *Service* for `/healthz`, so it proves Service selector -> pod -> app, which
`--wait` (pods Ready) does not. It reuses the app image (python is already in it).

**`../ci-rbac.yaml`** is not chart content (it sits one level up so `helm package` does not
ship it). Helm stores each release revision as a **Secret**, so the CI agent needs Secret rights
that plain `kubectl apply` never did. See the file for the Role.

## How it maps to the old `k8s/deployment.yaml`

`helm template demo-api demo-api -n demo-ci` renders the same Deployment and Service shape:

| | old manifest | chart | why |
|---|---|---|---|
| names | `demo-api` | `demo-api` (release `demo-api`) | `fullname` helper |
| container port, port name | 8080, `http` | same | `containerPort` |
| readiness probe | `/healthz`, period 5, failureThreshold 3 | same | `readinessProbe` in values |
| liveness probe | `/healthz`, delay 10, period 10 | same | `livenessProbe` in values |
| strategy | RollingUpdate, maxUnavailable 0, maxSurge 1 | same | `strategy` in values; a bad image stalls instead of dropping capacity |
| replicas, revisionHistoryLimit | 2, 5 | 2, 5 (omitted when autoscaling) | |
| resources | req 50m/64Mi, limit 256Mi | same by default (staging is smaller) | |
| env `FAIL_HEALTH` | literal env var | ConfigMap + `envFrom` | config changes now roll pods via the checksum |
| labels | `app`, `backstage.io/kubernetes-id` | **kept**, plus `app.kubernetes.io/*`, `helm.sh/chart` | `kubectl get pods -l app=demo-api` and Backstage keep working |
| selector | `app: demo-api` | `app.kubernetes.io/name` + `instance` | Helm convention, includes the release so two releases do not share pods |
| image | `IMAGE_PLACEHOLDER` + `sed` in `deployToEks` | `image.repository` + `image.tag` | a typed value, not a text substitution |
| Service type | NodePort 30095 | ClusterIP (NodePort optional) | no port clash between releases |
| container securityContext | nonroot, no privilege escalation | same, plus `drop: [ALL]` and pod-level `RuntimeDefault` seccomp | tighter, behaviour identical |
| ServiceAccount | default, token mounted | own, **token not mounted** | the app never talks to the API |
| new objects | | ConfigMap, ServiceAccount, optional Ingress/HPA, test pod | |

Differences are deliberate, never accidental; everything the drills rely on (ports,
probes, `app=demo-api` label, rolling-update strategy, `FAIL_HEALTH`) behaves the same.

## Releases: install, upgrade, rollback, `--atomic`

```sh
helm upgrade --install demo-api oci://REGISTRY/platform-lab/charts/demo-api --version 0.1.0-build.7 \
     -n demo-helm-ci -f values-staging.yaml --set image.tag=main-ab12cd34-7 \
     --atomic --wait --timeout 3m
helm -n demo-helm-ci history demo-api      # one row per revision
helm -n demo-helm-ci rollback demo-api 1   # a NEW revision whose content is revision 1
helm -n demo-helm-ci get values demo-api   # what was supplied (get manifest = what was applied)
helm -n demo-helm-ci test demo-api
```

- **`upgrade --install`** = install if absent, else upgrade: one idempotent command for a pipeline.
- **A revision is a Secret** (`sh.helm.release.v1.demo-api.vN`) holding the chart, the values and the
  rendered manifest. `helm list`, `history`, `rollback` all read those. (Hence the RBAC.)
- **`--wait`** blocks until Deployments are fully rolled out and Services have endpoints, **or**
  the `--timeout` expires. Without it `helm upgrade` returns as soon as the API server accepts
  the objects, the same trap as `kubectl apply` without `rollout status`: a green pipeline in front
  of crash-looping pods.
- **`--atomic`** = wait + **automatic rollback** if the upgrade fails or times out (a failed *first*
  install is uninstalled). History then shows: rev 1 superseded, rev 2 **failed**, rev 3 "Rollback to 1".
  It is the Helm version of what `deployToEks` does by hand (`rollout status` ... `rollout undo`).
  Helm 4 (the `alpine/k8s` agent container ships 4.2.1) prints "Flag --atomic has been deprecated,
  use --rollback-on-failure" but still honours it; Helm 3 only knows `--atomic`.
- **Helm 4 quirk seen here**: `helm test` on Helm 4.2.1 spends about its whole `--timeout` on hook
  bookkeeping even though the test pod finishes in 3 s (98 s with `--timeout 90s`, 35 s with `15s`, in
  the debug log "waiting for resources to be deleted"), so the pipeline uses `--timeout 30s`.
- **Rollback is not magic**: it restores the *manifest*, not data, not a ConfigMap you changed by hand,
  and not anything outside the chart. Two rollbacks in a row ping-pong between revisions.
- `helm upgrade` does a **three-way merge** (old chart, new chart, live state), so a field someone
  edited with `kubectl edit` that the chart does not set is left alone. This differs from Argo CD, below.

## In CI: `Jenkinsfile.helm`

Opt-in. Create a Jenkins pipeline job with *Script Path* `Jenkinsfile.helm` (parameters: environment,
namespace, release, optional image tag, one optional `--set`, timeout). Stages:

1. **Lint**: `helm lint` with the defaults and with **each** `values-*.yaml` (this is where the schema bites).
2. **Template**: renders what would be applied, archived as `rendered.yaml`.
3. **Package**: `helm package --version 0.1.0-build.<N>`.
4. **Build image** (skipped when `IMAGE_TAG` is given): the library's own `buildImage`.
5. **Push chart**: `helm push ... oci://$PLATFORM_REGISTRY/platform-lab/charts` (`--plain-http` for the
   playground's HTTP registry, an ECR login for ECR).
6. **Deploy**: `helm upgrade --install --atomic --wait --timeout` **from the registry** (what was pushed
   is what runs), `-f values-<env>.yaml`, `--set image.tag=<built tag>`.
7. **Test**: `helm test`.

**Where Helm runs.** In the shared library's existing `deploy` container (`alpine/k8s:1.33.13`, pinned in
`ci/shared-library/resources/podtemplates/build.yaml`), which already ships Helm 4.2.1. So there is
nothing to add to the shared pod template; `Jenkinsfile.helm` just loads that template and uses
`container('deploy')`. Helm reaches the cluster as the agent's ServiceAccount, in-cluster.

**Why there is no `helmRelease.groovy` step in the shared library** (it would be the natural
refactor). Adding a file to `ci/shared-library/vars/` does not touch what drill 09's `check.sh`
compares (it diffs only `standardPipeline`, `buildImage`, `deployToEks`, `src`, `resources`
against the `baseline` tag), so the drills would likely survive. I still kept the logic in the
Jenkinsfile because: (1) a new step is a library **release**, and the playground's `v1.0.0` /
`baseline` are frozen on purpose (drills 07 and 09 teach tags and additive releases; drill 09
literally asks the candidate to ship a new step, so a pre-existing one blurs it); (2) the
seed skips repos that already exist, so a step added to the source would be missing from every
already-seeded Gitea, and `Jenkinsfile.helm` would work on one machine and not on another;
(3) one file that reads top to bottom is better for explaining. A good exercise is to extract
the Deploy stage into `helmRelease(...)` and release it as `v1.1.0`.

**What the pipeline needs in the cluster**: `chart/ci-rbac.yaml` (a Role for Secrets and the
chart's kinds in the *target namespace only*; apply it with cluster-admin, a pipeline must not
be able to grant itself rights). The default agent Role (`deployer` in `demo-ci`) cannot write
Secrets, so Helm there would say `secrets is forbidden`.

## OCI registries and the Artifactory note

A chart is packaged as a `.tgz` and, since Helm 3.8, pushed to any **OCI registry** the same way
as an image: `helm push demo-api-0.1.0.tgz oci://host/path`, `helm pull`, `helm show chart`,
`helm install oci://host/path/demo-api --version X`. The registry stores it as an OCI artifact
under `path/demo-api:<version>` (the chart version *is* the tag). No `index.yaml`, no
`helm repo add`. The older style, a static HTTP server serving `index.yaml` plus `.tgz` files
(`helm repo add`, `helm install repo/chart`), is still what most public charts use.

Which registry:

- **The playground**: `kind-registry:5000` (plain HTTP, so `--plain-http`).
- **The home lab**: the platform's own `registry:3` in namespace `registry` (NodePort 30500).
  It is a plain distribution registry, so it also stores OCI charts. Argo CD does not need it for
  the demo: Argo reads the chart straight from this git repo.
- **AWS**: ECR supports OCI charts (one repository per chart, created beforehand, e.g.
  `platform-lab/charts/demo-api`).
- **Artifactory OSS cannot be the Helm registry**: Helm (and Docker/OCI) repository types are a
  **Pro** feature; OSS gives generic and Maven only (`homelab/platform/README.md`). That is the
  same reason the lab's *image* registry is a separate `registry:3`.

## In GitOps on the home lab (Argo CD)

`homelab/platform/apps/90-demo-api-helm.yaml` deploys this very directory from git
(`path: ci/apps/demo-api/chart/demo-api`, `valueFiles: [values-staging.yaml]`) into namespace
`demo-helm`, next to (not replacing) the Jenkins-deployed demo-api in `demo-ci`. The namespace is
added to `homelab/platform/project.yaml` (`destinations`), which is applied by hand.

The part that surprises people: **Argo CD does not run `helm install`**. It runs `helm template`
and applies the YAML like any manifest. Consequences you can demonstrate:

- `helm list -n demo-helm` is **empty**, and `kubectl -n demo-helm get secret` has no
  `sh.helm.release.v1.*`. The record of "what is deployed" is the Argo `Application`, not a Helm release.
- there is **no `helm rollback`** (nothing to roll back). Rollback = `git revert` the commit and push.
- a values change rolls out by **commit**: edit `values-staging.yaml` (a new `image.tag`, or
  `replicaCount`), push to `feat/playground`; Argo notices within ~3 minutes (or on a webhook / manual
  refresh), re-renders, and applies the difference. The checksum annotation makes a `config:` change
  roll the pods too.
- drift is reverted: `kubectl scale --replicas=5` is put back to 2 in seconds (`selfHeal`). Flux's
  helm-controller (which *does* run a real `helm upgrade`) behaves differently: see `AGENTS.md` section 4d.
- `helm test` hooks are not run by Argo. The test pod is a Helm-only concept.

## Interview: the 60-second version

"Our own app is a chart with a values file per environment and a JSON schema, so a typo fails at lint,
not at 3 a.m. CI lints every environment file, packages, pushes the chart to an OCI registry as an
immutable version, then `helm upgrade --install --atomic --wait` from that artifact, so a bad
release rolls itself back, then `helm test` checks the Service end to end. On the cluster, Argo CD
renders the same chart with `helm template` from git, so there's no Helm release at all: the deploy
is a commit and the rollback is a revert. Pods roll on config changes because the Deployment carries
a checksum of the ConfigMap."

Likely follow-ups: *Helm vs Kustomize* (templating vs patching; Helm adds packaging, versioning and a
release record, Kustomize has no logic to learn), *why not `latest`* (see the schema), *secrets*
(not in values; sealed-secrets/SOPS/external-secrets, see `gitops/secrets/`), *helm 3 vs 4* (renamed
flags, watcher-based `--wait`), *what `--atomic` cannot undo* (data, non-chart objects, CRDs).


## Verification log (2026-10-18)

Local: Helm 3.20.0. CI runs Helm 4.2.1 (the `alpine/k8s:1.33.13` agent container).

- `helm lint` clean (only the "icon is recommended" INFO) with the defaults, `values-staging.yaml`, `values-prod.yaml`.
- Schema: `--set replicaCount=two`, `--set replicaCnt=3`, `--set image.tag=latest`, `--set image.tag=`,
  `--set service.type=NodeProt` are all rejected before rendering (messages above).
- `helm template -f values-prod.yaml` adds a HorizontalPodAutoscaler and an Ingress and drops `replicas`.
- `helm package` contains no `values-*.yaml` (`.helmignore`).
- **Local kind playground, throwaway Jenkins job + namespace `demo-helm-ci`, `Jenkinsfile.helm`:**
  - build 2 (first install): lint, template, package, image build+push, chart pushed to
    `oci://kind-registry:5000/platform-lab/charts/demo-api:0.1.0-build.2`, `helm upgrade --install --atomic --wait`
    deployed revision 1, `helm test` -> `Phase: Succeeded`, pod log `http://demo-api:80/healthz {'status': 'ok'}`.
    `helm show chart oci://localhost:5001/platform-lab/charts/demo-api --version 0.1.0-build.3 --plain-http`
    works from the host.
  - build 3 (healthy upgrade): revision 2, `helm test` passed.
  - build 4 (`EXTRA_SET=config.FAIL_HEALTH=true`, `TIMEOUT=90s`): the ConfigMap checksum rolled the pods, the new
    pod's `/healthz` returned 500, `maxUnavailable: 0` kept the two good pods serving, `--wait` timed out and
    `--atomic` rolled back; the build failed with "rolled back to the last good revision":

    ```
    1  superseded  demo-api-0.1.0-build.2
    2  superseded  demo-api-0.1.0-build.3
    3  failed      demo-api-0.1.0-build.4  Upgrade "demo-api" failed: resource Deployment/... not ready ...
    4  deployed    demo-api-0.1.0-build.3  Rollback to 2
    ```
    The ConfigMap was back to `FAIL_HEALTH: "false"` and both original pods were still Running, never restarted.
  - Afterwards the job, scratch repo, namespace (release Secrets included), registry tags and node images were
    deleted; `play doctor` green; `demo-api` `main` still green.
- Not exercised: the ECR login branch of `Jenkinsfile.helm`, the `prod` environment (no ingress controller or
  metrics-server in kind), Helm 3 as the *CI* Helm.
- **Home lab (RKE2 + Argo CD)**: after `project.yaml` (new destination `demo-helm`) was applied by hand and the
  commit pushed, `homelab-platform` created `demo-api-helm`: **Synced / Healthy** in about a minute, two
  pods Running in `demo-helm`, image `10.77.0.31:30500/platform-lab/demo-api:main-488bac7e-3` (the tag the
  Jenkins-deployed `demo-ci` pods run), `GET /` answers `{"app":"demo-api","version":"main-488bac7e-3"}`.
  `helm list -n demo-helm` printed **no releases** and `kubectl -n demo-helm get secret` is empty.
  The `helm test` pod is not applied by Argo (it is not among the Application's resources).
  Values change: `replicaCount: 3` plus a new `config` key pushed to git -> Argo re-rendered, the ConfigMap
  hash changed, a new ReplicaSet rolled 3 new pods (ConfigMap shows the new key). `git revert` of that commit
  -> back to 2 pods and the original ReplicaSet within ~1 minute (Argo's default poll, here nudged with a
  hard refresh). `demo-ci/demo-api` (Jenkins, plain manifests) was untouched.
