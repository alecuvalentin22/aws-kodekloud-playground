# Exercise: package your own service as a Helm chart (60 to 90 minutes)

Not a scored drill: nothing is broken for you and there is no clock. Until now you have
*consumed* other people's charts (Jenkins, Prometheus, Artifactory). Here you do the other
half of Helm: you get a small service you have never seen, **package it from nothing**,
publish it to a registry, release it, upgrade it, and watch a bad upgrade undo itself.

```text
helm create  ->  trim  ->  Chart.yaml + values.yaml
   -> Deployment + Service + ConfigMap (+ _helpers.tpl, checksum, probes, resources)
   -> values.schema.json (rejects typos)  ->  values-staging.yaml / values-prod.yaml
   -> helm lint / helm template / helm upgrade --dry-run=server
   -> helm package + helm push (OCI registry)
   -> helm upgrade --install FROM the registry --atomic --wait   ->  helm test
   -> config change (pods roll: checksum)  ->  broken upgrade (--atomic rolls it back)
   -> helm history
```

When you are done you can say "I have built this", and answer *"how do you package and release
an application with Helm?"* with your own chart as the example. The worked example in this repo
is `ci/apps/demo-api/chart/demo-api/` (its README explains every file); you will build a
different chart from scratch and **only look at that one when you are stuck**.

| Step | You do | Minutes |
|---|---|---|
| 0 | set up, meet the service | 7 |
| 1 | `helm create`, then **trim** it; `Chart.yaml`, `values.yaml` | 12 |
| 2 | Deployment + Service + ConfigMap, helpers, checksum, probes, resources, test | 18 |
| 3 | `values.schema.json` that rejects realistic typos | 8 |
| 4 | `values-staging.yaml` / `values-prod.yaml` | 5 |
| 5 | `helm lint`, `helm template` (read it like a review), `--dry-run=server` | 8 |
| 6 | package, push to the OCI registry, install **from** it, `helm test` | 10 |
| 7 | config upgrade (pods roll), broken upgrade (rolls back), `helm history` | 12 |
| 8 | `./check.sh`, the Q&A, `./cleanup.sh` | 10 |

You need the playground running (`play doctor` all green), Docker, `helm` (3.x or 4.x), `kubectl`,
`jq`, and a terminal on the machine that runs it. The cluster is context `kind-playground`
(`kubectl config current-context`; `kubectl config use-context kind-playground` if it is not).
Namespace used: `ex-helm-notes` (no drill touches it). Registry: **`localhost:5001` from your
machine, `kind-registry:5000` from inside the cluster**: the same registry, two names. You run
everything as cluster admin; see the last section for what a CI agent would additionally need.

---

## 0. Set up, and meet the service

```bash
cd <repo>/playground/exercises/helm-chart
./seed.sh
```

It creates the namespace **`ex-helm-notes`**, your working copy **`~/platform-playground/notes-api`**
with the service's source, and builds and pushes the image as
`localhost:5001/helm-lab/notes-api:1.0.0` and `:1.1.0` (the cluster pulls it as
`kind-registry:5000/helm-lab/notes-api:<tag>`). The chart is **yours**: you add it under `chart/`.

Read, in `~/platform-playground/notes-api`:

* `app.py`: **notes-api**, Python standard library only. `GET /healthz` -> `{"status": "ok"}`,
  `GET /` reports its config, `POST /notes` stores a note in memory. Its behaviour is **driven by
  three environment variables**: `MAX_NOTE_LENGTH` (default 280; a longer note gets HTTP 413),
  `READ_ONLY` (`true` makes POST answer 403) and `LOG_LEVEL`. A bad value (`MAX_NOTE_LENGTH=lots`)
  stops the process at startup. It listens on port 8080 and needs no volume, no secret, no database.
* `Dockerfile`: pinned base, non-root numeric uid 10001, nothing writes to disk (so a read-only root
  filesystem works).
* `python3 -m unittest -q` runs its tests.

Those three variables are what the chart's **ConfigMap** will carry. Change one in a release and the
running pods must pick it up: that is step 2's checksum and step 7's rollout.

**The contract with `check.sh`.** Name things like this, so the check can find them:

| | |
|---|---|
| chart, release | `notes-api` (in `~/platform-playground/notes-api/chart/notes-api`), release `notes-api`, namespace `ex-helm-notes` |
| values | `replicaCount`, `image.repository`, `image.tag`, `service.type`, `service.port`, and `config.MAX_NOTE_LENGTH`, `config.READ_ONLY`, `config.LOG_LEVEL` (defaults `"280"`, `"false"`, `info`) |
| image | repository `kind-registry:5000/helm-lab/notes-api`, tag `1.0.0` |
| registry | chart pushed to `oci://localhost:5001/helm-lab/charts` |

> **Reference solution:** `solution/` is the finished chart (and `solution/walkthrough.sh` plays
> steps 5 to 7 with it). It is clearly marked, and it is for **comparing** after you wrote yours.

## 1. `helm create`, then trim

```bash
cd ~/platform-playground/notes-api && mkdir -p chart && cd chart
helm create notes-api
find notes-api -type f | sort
```

**What the scaffold gives you:** a working nginx chart: `Chart.yaml` (`appVersion: "1.16.0"`, an nginx
version), a 160-line `values.yaml`, and templates for a Deployment, a Service, a ServiceAccount, an
Ingress, an HPA, a Gateway-API `HTTPRoute`, `NOTES.txt`, `_helpers.tpl` and a `tests/test-connection.yaml`
that runs an *unpinned* `busybox` doing `wget` on `/`.

**Why most of it gets deleted.** The scaffold is a showcase of *every optional feature*, written for no
service in particular. In a real chart every template you do not need is a file that someone must
read, a value that needs a schema entry, and a branch to test. Keep what *your* service needs:

```bash
cd notes-api/templates
rm hpa.yaml ingress.yaml httproute.yaml serviceaccount.yaml      # notes-api is cluster-internal and fixed-size
```

Keep `_helpers.tpl` (you will read it in step 2), `deployment.yaml`, `service.yaml`, `NOTES.txt` and the
`tests/` directory; you will rewrite most of their content. Add `configmap.yaml` yourself.

**`Chart.yaml`.** Edit it to be about *notes-api*: `description`, `type: application`, and the two
versions people mix up:

* `version: 0.1.0` is the version of **the packaging** (templates, values, schema). SemVer. It becomes the
  OCI tag, so it must be **unique per published chart**: bump it whenever anything in the chart changes.
* `appVersion: "1.0.0"` is the version of **the software** inside. Information only (`helm list` prints it).
  It does **not** choose the image; `values.yaml` does. (Step 7 shows them moving independently.)

**`values.yaml`.** Delete the scaffold's and write a short one: `replicaCount: 2`, `image` (`repository`,
`tag`, `pullPolicy`), `config` (the three variables, as **strings**: environment variables are strings),
`service` (`type: ClusterIP`, `port: 80`), `resources`, and whatever your probes and
`securityContext` need. Two rules: every key is a decision a user may make (not a template detail),
and **the image tag is not defaulted to `appVersion`** the way the scaffold does it. The image is a deploy
decision. It is also where `latest` sneaks in, which step 3 forbids.

## 2. Deployment + Service + ConfigMap

**`templates/_helpers.tpl`** already defines `notes-api.name`, `.fullname`, `.chart`, `.labels`,
`.selectorLabels` (and a service-account helper you can delete). Read them, then make sure of one thing:
the **selector labels** are only `app.kubernetes.io/name` and `app.kubernetes.io/instance`, never a
version. A Deployment's selector is **immutable**, and the Service selects pods with the *same helper
text*, so the two cannot drift apart (a Service whose selector does not match has no endpoints: "connection
refused" with healthy pods; playground drill 74).

**`templates/configmap.yaml`**: one key per entry of `.Values.config`. Quote and stringify every value
(`{{ $v | toString | quote }}`): YAML would otherwise turn `false` into a boolean, and a ConfigMap
value must be a string.

**`templates/deployment.yaml`**: the container reads its config with
`envFrom: configMapRef: name: <fullname>`, sets `PORT` from `containerPort`, has a named port `http`,
a **liveness and a readiness probe on `/healthz`**, **`resources`** (requests and a memory limit),
`securityContext` (non-root, `readOnlyRootFilesystem: true`, drop all capabilities), and a rolling update
with `maxUnavailable: 0`. The one line that matters most is on the pod template:

```yaml
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

**Why:** Kubernetes only restarts pods when the **pod template** changes. A ConfigMap edit changes
nothing in the template, so after `helm upgrade --set config.MAX_NOTE_LENGTH=100` you would have a new
ConfigMap and pods still running with the old environment. Hashing the rendered ConfigMap into the
template turns every config change into a template change, hence a rolling update. (Nuance: you are hashing
the *whole rendered file*, labels included. If your `labels` helper puts the image tag in a label, a new
image tag also changes the checksum. Harmless, because the image changed the pod template anyway; know why.)

**`templates/service.yaml`**: `ClusterIP`, `port: {{ .Values.service.port }}`, `targetPort: http`, selector from
the selector-labels helper.

**`templates/tests/test-connection.yaml`**: replace the scaffold's. A `helm test` pod
(`"helm.sh/hook": test`) should ask the **Service** (not a pod) for `/healthz` and fail unless it gets
`{"status": "ok"}`. Reuse the *app image* (it has Python; `python -c "import urllib.request ..."`):
no second image to pull, nothing unpinned. Give it labels that do **not** include the selector labels,
or the Service would send real traffic to your test pod.

**`templates/NOTES.txt`**: how to check and reach it (`kubectl port-forward svc/...`).

## 3. `values.schema.json`

A JSON Schema next to `values.yaml`. Helm checks it on `lint`, `template`, `install` and `upgrade`, **before**
anything reaches the cluster. Without it, `replicaCnt: 5` is silently ignored (you think you scaled, you
did not), and `replicaCount: "two"` produces a Deployment the API server rejects halfway through an upgrade.

Write one (`"$schema": "http://json-schema.org/draft-07/schema#"`) that makes **at least two** of these fail,
with the mechanism in brackets:

```bash
helm template x notes-api --set replicaCnt=3          # misspelt key        [additionalProperties: false]
helm template x notes-api --set replicaCount=two      # wrong type          ["type": "integer"]
helm template x notes-api --set service.type=NodeProt # not a real type     [enum]
helm template x notes-api --set image.tag=latest      # a moving tag        ["not": {"const": "latest"}]
helm template x notes-api --set config.LOG_LEVL=debug # misspelt setting    [additionalProperties: false inside config]
```

Run them *before* you write the schema (they all succeed: that is the problem), then after. Make
`additionalProperties: false` at the top **and** inside `image`, `service` and `config`, `required` the
keys you cannot work without, and leave pass-through blocks you do not own (`securityContext`, probes)
as plain `{"type": "object"}`. **The trade-off to be able to say:** a strict schema must be edited
whenever you add a value, or users get "additional properties not allowed" for a legitimate key.

## 4. `values-staging.yaml` and `values-prod.yaml`

Next to `values.yaml`, containing **only what differs** from the defaults: staging is the small, noisy one
(`config.LOG_LEVEL: debug`), prod is the big, quiet one (`replicaCount: 3`, larger `resources`,
`LOG_LEVEL: warn`, a longer `MAX_NOTE_LENGTH`). Same chart, one file per environment: that is how Helm
avoids a copy of the manifests per environment. Prod is lint-and-render only here. Add a `.helmignore`
line `values-*.yaml`: a package is environment-agnostic, the environment file is chosen at install time
(`-f`).

## 5. `helm lint`, `helm template`, `--dry-run=server`

```bash
cd ~/platform-playground/notes-api/chart
helm lint notes-api
helm lint notes-api -f notes-api/values-staging.yaml
helm lint notes-api -f notes-api/values-prod.yaml
helm template notes-api notes-api -n ex-helm-notes -f notes-api/values-staging.yaml | less
helm upgrade --install notes-api notes-api -n ex-helm-notes -f notes-api/values-staging.yaml --dry-run=server
```

(The "icon is recommended" INFO is fine; an `[ERROR]` is not.) Three different questions:

* **`lint`**: is the chart well-formed, does it satisfy the schema? Run it with *every* environment file.
* **`template`**: what YAML would Helm hand to the API server? **Read it like a pull-request review**, not like
  a log. Tick off: the Deployment's `selector.matchLabels` equals the Service's `selector`; the
  `checksum/config` value is there; the container image is `kind-registry:5000/helm-lab/notes-api:1.0.0`
  (not an empty tag); the probe port is the *named* port; the ConfigMap has three string values.
  Then diff the staging and prod renders: `diff <(helm template ... -f staging) <(helm template ... -f prod)`.
* **`--dry-run=server`**: the API server validates and admission-checks the objects (and `lookup` works)
  without storing anything. `template` and `--dry-run=client` cannot know that a CRD is missing or that a
  quota would be exceeded.

## 6. Package, push to the registry, install from it

```bash
cd ~/platform-playground/notes-api/chart
helm package notes-api                                   # -> notes-api-0.1.0.tgz
helm push notes-api-0.1.0.tgz oci://localhost:5001/helm-lab/charts --plain-http
helm show chart oci://localhost:5001/helm-lab/charts/notes-api --version 0.1.0 --plain-http

helm upgrade --install notes-api oci://localhost:5001/helm-lab/charts/notes-api --version 0.1.0 --plain-http \
     -n ex-helm-notes -f notes-api/values-staging.yaml --atomic --wait --timeout 90s
helm -n ex-helm-notes list
helm -n ex-helm-notes test notes-api
kubectl -n ex-helm-notes get deploy,svc,pods,cm -l app.kubernetes.io/instance=notes-api
```

* A chart is a `.tgz`; an OCI registry stores it **like an image**: `<registry>/<path>/<name>:<chart version>`.
  `--plain-http` because the playground registry has no TLS. No `helm repo add`, no `index.yaml`.
* You install **from the registry**, not from the directory, so what was pushed is what runs. The
  environment file is still a local `-f`: it is not in the package.
* `upgrade --install` = install if absent, else upgrade: one idempotent command for a pipeline.
* **`--wait`** blocks until the Deployment is fully rolled out (or `--timeout` expires). **`--atomic`**
  = wait, and **roll back automatically** if it fails or times out (a failed *first* install is
  uninstalled). Without them `helm upgrade` returns as soon as the API server accepted the objects: the
  same trap as `kubectl apply` without `rollout status`. (Helm 4 prints that `--atomic` is deprecated for
  `--rollback-on-failure`; both work.)
* `helm test` created your test pod, waited, and reported its exit code. Read what it said:
  `kubectl -n ex-helm-notes logs notes-api-test-connection`.

Try the service: `kubectl -n ex-helm-notes port-forward svc/notes-api 8080:80`, then `GET /`, `POST /notes`
with `{"text": "hello"}` (`curl -s -XPOST localhost:8080/notes -d '{"text":"hello"}'`).

## 7. Upgrade, break it on purpose, read the history

Watch in a second terminal: `kubectl -n ex-helm-notes get pods,rs -w`.

**7a. A config change.** `MAX_NOTE_LENGTH` 280 -> 100:

```bash
helm upgrade notes-api oci://localhost:5001/helm-lab/charts/notes-api --version 0.1.0 --plain-http \
     -n ex-helm-notes -f notes-api/values-staging.yaml --set config.MAX_NOTE_LENGTH=100 \
     --atomic --wait --timeout 90s
```

The chart did not change (still 0.1.0), only a value. Yet **the pods rolled**: a new ReplicaSet, two new pods,
the old ones removed one at a time (`maxUnavailable: 0`). That is the checksum. Prove it: `GET /` now says
`max_note_length: 100`, a 150-character POST answers 413, and `helm -n ex-helm-notes get values notes-api`
shows what you supplied. Comment out the checksum line, repeat with a different value and watch nothing
restart (do not push that chart; put the line back).

> Every `helm upgrade` **replaces** the user-supplied values, it does not add to them. Repeat `-f` and
> every `--set` you still want, or use `--reset-then-reuse-values`. Forgetting this is the classic "my
> upgrade silently undid last week's setting".

**7b. A broken upgrade.** An image tag that does not exist (a typo that passes the schema):

```bash
helm upgrade notes-api oci://localhost:5001/helm-lab/charts/notes-api --version 0.1.0 --plain-http \
     -n ex-helm-notes -f notes-api/values-staging.yaml --set config.MAX_NOTE_LENGTH=100 \
     --set image.tag=1.1.1 --atomic --wait --timeout 60s
```

It fails after 60 seconds. In the second terminal: a new pod in `ErrImagePull` / `ImagePullBackOff`, **while the
two good pods keep serving** (rolling update, `maxUnavailable: 0`), then `--atomic` undoes the release. Now:

```bash
helm -n ex-helm-notes history notes-api
```

```text
1  superseded  Install complete
2  superseded  Upgrade complete
3  failed      Upgrade "notes-api" failed: context deadline exceeded
4  deployed    Rollback to 2
```

Revision 3 is kept (it is the evidence), and the rollback is a **new** revision (4) whose content is
revision 2. Check: `helm get values notes-api` still has `MAX_NOTE_LENGTH: 100`, and the pods are the same
two that were running before (never restarted: the revision-2 ReplicaSet was never scaled down).
Try also `helm -n ex-helm-notes rollback notes-api 1` by hand, and `kubectl describe pod` on a failed
pod to find the reason.

**Optional:** ship `--set image.tag=1.1.0` (a real image). `GET /` reports version 1.1.0 while `helm list`
still says `APP VERSION 1.0.0` and `CHART notes-api-0.1.0`: three different "versions", on purpose.
Another bad release, with a semantic mistake that your schema might catch **earlier** (and if it does, that
is the schema doing its job): `--set config.MAX_NOTE_LENGTH=lots` crash-loops the pods instead.

## 8. Check, talk, clean up

```bash
./check.sh        # ✓/✗ per step; exits 0 when everything required passes
```

`check.sh` verifies: the chart's files; `helm lint` with the defaults and each `values-*.yaml`; that the
schema rejects the typos above (at least 2 of 4); that staging and prod render differently; that the API
server accepts it (`--dry-run=server`); that the chart is in the OCI registry and the package carries the
schema and the test; that the release is `deployed` in `ex-helm-notes` with revision >= 3, a **failed**
revision followed by a **`Rollback to`**, and a running chart version that is a registry tag; that the
Deployment's pods are all Ready, the pod template has the `checksum/config` annotation and the
ReplicaSet history shows more than one checksum; that the Service has endpoints and answers `/healthz`;
that the live config (`max_note_length`) is the ConfigMap's and is **not** the chart default; and that
`helm test` passes (this one creates the test pod). It changes nothing else.

Then say the Q&A below out loud, then:

```bash
./cleanup.sh      # release, namespace, registry tags (image and chart), local image tags. Your chart stays; --work removes it too.
```

---

## Interview Q&A

**1. Chart vs release vs revision?**
A *chart* is the package: templates plus a defaults file plus metadata. A *release* is one installation
of a chart in a namespace, with a name (`notes-api`); you can have many releases of one chart. A *revision*
is one numbered state of a release: every install, upgrade and rollback creates a new one. `helm history`
lists them.

**2. How is Helm 3 different from Helm 2? And Helm 4?**
Helm 2 had **Tiller**, a server-side component with cluster-admin that every client talked to: a security
and multi-tenancy problem. Helm 3 removed it: the client talks to the API server with *your* kubeconfig
and RBAC. Helm 3 also stores state in the release's own namespace, supports OCI registries and JSON-schema
validation. Helm 4 keeps charts and commands compatible but changes internals and flags: server-side apply
instead of the three-way merge for new installs, a watcher-based `--wait`, and `--atomic` renamed
`--rollback-on-failure` (the Jenkins agent image here ships Helm 4.2.1; your laptop may have 3.x).

**3. Where does Helm keep a release's state?**
In the cluster, as **Secrets** in the release's namespace named `sh.helm.release.v1.<name>.v<N>`, one per
revision, each holding the chart, the values and the rendered manifest (gzip + base64). `kubectl -n
ex-helm-notes get secret` shows them. Consequences: a CI agent needs Secret rights in the namespace (see
`ci/apps/demo-api/chart/ci-rbac.yaml`); the values are readable by anyone who can read those Secrets, so
real secrets do not belong in values; `helm history` is capped by `--history-max` (default 10).

**4. `helm template` vs `helm install` (vs `--dry-run`)?**
`template` renders locally and prints YAML: no cluster, no release, and it cannot know server-side
facts (`lookup` returns nothing, `.Capabilities` are guessed). `install` renders **and** applies and
records a revision. `--dry-run=client` renders as install would without storing; `--dry-run=server`
also sends the objects to the API server for validation and admission, still without storing. Use `lint` +
`template` in CI, `--dry-run=server` for the "will my cluster take this" question.

**5. What are hooks?**
Templates with a `helm.sh/hook` annotation (`pre-install`, `post-upgrade`, `pre-delete`, `test`, ...) that
Helm runs at a point of the lifecycle and does **not** manage as part of the release (no upgrade, not removed
on uninstall unless `hook-delete-policy` says so). Typical use: a DB migration Job in `pre-upgrade`. `helm test`
runs the `test` hooks: your connection-check pod. Pitfall: a hook that hangs blocks the upgrade; make
hooks idempotent.

**6. Why does Argo CD render charts instead of running `helm install`, and what do you lose?**
Argo CD wants the *git* repo to be the truth and to own every object, so it runs `helm template` and applies
the output like any manifest (and compares live to rendered for drift). So there is **no release**: `helm
list` is empty, there are no `sh.helm.release.v1` Secrets, **no `helm rollback`** (rollback is a `git
revert`), **no `helm test`** and no hooks run as Helm hooks (Argo maps some to its own sync hooks).
You gain drift detection, `selfHeal`, pruning and one UI for all apps. Flux's helm-controller, in contrast, runs
a real `helm upgrade`.

**7. Values precedence?**
Lowest to highest: the chart's `values.yaml`; a parent chart's values for a subchart; `-f` files in the order
given (the last wins); `--set` / `--set-string` / `--set-file` (the last wins, and always beat files).
Maps are merged key by key; **lists are replaced whole**. And `helm upgrade` starts from the chart defaults
again unless you pass `--reuse-values` or `--reset-then-reuse-values`. Habit: reviewable settings in files
in git, only what CI computes (the image tag) in `--set`.

**8. `--wait`, `--atomic`, `--timeout`?**
`--wait`: do not return until Deployments are rolled out, Services have endpoints, PVCs are bound, or
`--timeout` (default 5m) expires, in which case the release is marked *failed*. `--atomic` implies `--wait`
and on failure rolls back to the previous revision (uninstalls a failed first install). It restores the
*manifests*, not data, and not objects outside the chart. It only protects you well together with a rolling
strategy that never removes capacity before the new pod is Ready (`maxUnavailable: 0`) and a **readiness
probe**: without a probe, "ready" is a lie and `--wait` passes.

**9. OCI registry vs a classic chart repository?**
A classic repo is a static HTTP server with an `index.yaml` listing `.tgz` files (`helm repo add`, `helm
repo update`, `helm install repo/chart`): most public charts. An OCI registry is the same registry you
already run for images (`helm push`, `oci://host/path/chart --version X`): no index to regenerate,
the same auth, replication and scanning as images, immutable-by-convention tags (the chart version *is*
the tag), digests for pinning. ECR and the playground's `registry:2/3` are OCI registries; Artifactory OSS
cannot host Helm (that needs Pro), which is why the lab's registries are separate.

**10. Subcharts, dependencies, library charts?**
`dependencies:` in `Chart.yaml` pulls other charts into `charts/` (`helm dependency update` writes
`Chart.lock`; `helm dependency build` restores from it). A **subchart** gets its values under its own
name key (`postgresql:`), can be switched with `condition:`/`tags:`, and shares `global:` values. Its objects
are part of *your* release. A **library chart** (`type: library`) installs nothing; it only exports named
templates other charts `include` (a company-standard labels/deployment definition): the DRY tool for many
similar services. Pitfall: coupling every service to one shared library version.

**11. `version` vs `appVersion`?**
`version` is the chart (packaging) version, SemVer, the OCI tag, bumped when anything in the chart changes.
`appVersion` is the application's version, informational. The image to run is `image.tag` in the values.
They move independently: a new image needs no new chart version, a new probe needs a new chart version and
no new image. CI often publishes `0.1.0-build.N` so every build has a unique tag.

**12. Why the `checksum/config` annotation?**
Pods restart only when the pod template changes; a changed ConfigMap changes nothing in it, so pods keep
the old environment. A hash of the rendered ConfigMap in a pod annotation makes a config change a template
change and triggers the rolling update. The alternatives: a tool such as Reloader that watches ConfigMaps,
or the app re-reading the file. Mounted ConfigMap *files* do refresh eventually; **env vars never do**.

**13. How do you test a chart?**
In layers, cheapest first: `helm lint` (every environment values file; `--strict`); the **values schema**
(typos fail early); `helm template` rendered and checked with `kubeconform`/`kubeval` against the Kubernetes
schemas and `conftest`/policy for rules; `helm install --dry-run=server`; `chart-testing` (`ct lint`, `ct
install` against a throwaway kind cluster, which also checks the version was bumped); then `helm test` on a
real release for behaviour (does the Service reach the app?). Unit-testing templates: the `helm-unittest`
plugin.

**14. When would you NOT use Helm?**
When there is nothing to parameterise: one app, one environment, plain manifests in git are easier to read
than templates. When you mostly *patch* someone else's manifests per environment: **Kustomize** (no
templating language, overlays, built into `kubectl`) is simpler and keeps the base valid YAML. When the
logic is complex enough that Go templates hurt: a CDK/Jsonnet/CUE-style generator or an operator. Helm earns
its keep for **distributing** software to people you do not control (versions, defaults, a values contract,
a registry) and for release records and rollback. They combine: Argo CD or Flux can render a chart and then
apply Kustomize patches.

**15. "I upgraded and my old setting disappeared", or "the pods did not restart after a config change".**
First: `helm upgrade` replaces user-supplied values (no `--reuse-values`), so the setting you did not pass
again went back to the default; `helm get values <release>` shows exactly what the current revision was
given, and `helm get values --revision N` the old one. Second: no checksum annotation (or a Secret/ConfigMap
that is not hashed, or a change that the hash does not cover). Look at `helm get manifest`, then the
ReplicaSets.

---

## What to do next in CI

`ci/apps/demo-api/Jenkinsfile.helm` is this exercise as a pipeline: `lint` (every values file) ->
`template` -> `package` -> push (OCI) -> `upgrade --install --atomic --wait` from the registry ->
`helm test`. Helm there runs as the Jenkins agent's ServiceAccount, which needs the namespaced Role in
`ci/apps/demo-api/chart/ci-rbac.yaml` (Secrets, because Helm stores each revision as one). A good
follow-up: take the chart you just wrote, add a Jenkinsfile with those stages, and run it.

**Verified 2026-10-18** on the Mac's kind playground (`play doctor` green, Helm 3.20.0, Docker 29, macOS bash 3.2):
the reference chart in `solution/` passes `check.sh` (55 of 55, exit 0) after `solution/walkthrough.sh` (about 75 s);
the bare `helm create` scaffold and a revision-1-only release fail with useful hints; `cleanup.sh` leaves nothing
behind (no namespace, release, registry tags or local image tags) and `play doctor` stays green. Not exercised: Helm 4 on the candidate side (the Jenkins agent ships 4.2.1 and
`Jenkinsfile.helm` is verified with it).
