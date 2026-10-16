# Home-lab platform (Argo CD app-of-apps)

The on-prem counterpart of `gitops/platform/` + `ci/`: the same tools (Jenkins,
Artifactory, Backstage, kube-prometheus-stack), declared as Argo CD
Applications for the **RKE2 cluster on the Incus VMs** (`rke2-s1` 10.77.0.31,
`rke2-a1` .32, `rke2-a2` .33), reusing the EKS work instead of redoing it.

> **Status: deployed and running on the RKE2 cluster since 2026-10-16** (all nine
> Applications Synced + Healthy). What was checked, and what was not, is in
> [Verified](#verified-2026-10-16) and [Not verified yet](#not-verified-yet).

## Layout

```
homelab/platform/
  project.yaml                 AppProject "homelab" (applied by hand with root.yaml)
  root.yaml                    the app-of-apps; watches apps/ on feat/playground
  apps/                        one Application per component (sync-wave annotated)
  values/                      Helm values, pulled in via Argo multiple sources ($values)
  manifests/                   plain manifests for things with no chart (registry, RBAC)
```

## What is deployed

The "JD line" column uses the wording of the README's requirements table and
`docs/ci-track.md` ("Jenkins pipelines, reusable pipeline code, AWS, EKS and
Docker"); the job description itself is not in the repo.

| Wave | App (file) | What it is | Pin | JD line it serves |
|---|---|---|---|---|
| - | Argo CD (installed by hand from the official manifest, see [`../argocd/README.md`](../argocd/README.md); not managed by this tree) | the GitOps controller | app v3.5.2 (`ARGOCD_VERSION`) | GitOps / declarative delivery |
| 0 | `00-local-path-storage` | default, node-local StorageClass (RKE2 has none) | **v0.0.37, released 2026-08-05** | Kubernetes storage / stateful workloads |
| 2 | `20-kube-prometheus-stack` | Prometheus + Alertmanager + Grafana | chart 88.6.2 (`KPS_VERSION`) | Monitoring / observability |
| 3 | `30-registry` | plain `registry:3` for CI images | **registry 3.1.1, pushed 2026-09-21** | Docker image build + push |
| 3 | `31-jenkins-rbac` | agent ServiceAccount, deploy rights in `demo-ci` only | n/a | least-privilege CI |
| 3 | `32-jenkins` | Jenkins, JCasC, shared library, `demo-api` multibranch job | chart 5.9.68 (`JENKINS_CHART`) | Jenkins pipelines, reusable pipeline code, branching workflows |
| 3 | `34-backstage-rbac` | read-only SA for Backstage's Kubernetes tab | n/a | developer portal |
| 4 | `40-backstage` | Backstage, catalog from this repo | chart 2.10.2 (`BACKSTAGE_CHART`), image 1.55.2 (`BACKSTAGE_IMAGE`) | developer portal / service catalog |
| 5 | `50-artifactory` | Artifactory OSS | chart 107.161.26 (`ARTIFACTORY_CHART`) | Artifact management |

Every chart version is the one in `versions.env`. The two pins that
`versions.env` does not have were looked up on 2026-10-16:

- **local-path-provisioner v0.0.37**, GitHub release dated 2026-08-05 (newest
  non-prerelease; v0.0.36 is 2026-05-08). It has no Helm repository, so Argo
  pulls the chart from the git tag `v0.0.37`, path `deploy/chart/local-path-provisioner`.
- **registry 3.1.1**, Docker Hub `library/registry`, pushed 2026-09-21. 3.1.2
  (2026-09-29) exists but is under two weeks old.

### Sync-wave order

`root.yaml` creates the children; the `argocd.argoproj.io/sync-wave` annotation
on each child orders them, and Argo waits for a wave to be Healthy before
starting the next -- **but only because of a health check added on 2026-10-16**:
`install.yaml` has none for `argoproj.io/Application` (removed in Argo CD 1.8), so
without it every child is "Healthy" the moment it exists and the annotations order
nothing. It lives in [`../argocd/argocd-cm.yaml`](../argocd/argocd-cm.yaml); after it
was applied the root app went Degraded while Artifactory was, and Healthy when it was:

```
0 storage -> 2 observability -> 3 CI tools -> 4 portal -> 5 Artifactory
```

Everything with a PVC needs wave 0. Wave 2 goes before 3 so the CRDs exist
(and Prometheus is up) before anything ships a ServiceMonitor. Backstage
(wave 4) comes after the CI tools its catalog describes. **Artifactory is the
last wave (5)** because it is the slowest to start and the likeliest to fail:
Argo waits for a wave to be Healthy before starting the next, so as wave 3 it
would have held Backstage back. (There is no wave 1: it used to hold an
ingress-nginx `HelmChartConfig`, removed on 2026-10-16: nothing in this stack
needs a cluster-wide ingress setting. The one large-body Ingress, Artifactory's,
carries its own `proxy-body-size` annotation, and the registry is reached by
NodePort, not through the Ingress.)

### Decisions worth knowing

**Registry for Jenkins images: a plain in-cluster `registry:3`, not Artifactory.**
Artifactory OSS has no Docker/OCI repository type (that is JFrog Container
Registry or Artifactory Pro). So `PLATFORM_REGISTRY=10.77.0.31:30500` and
`PLATFORM_REGISTRY_INSECURE=true` are set as Jenkins global env vars in JCasC
(`values/jenkins.yaml`). `ci/shared-library/vars/standardPipeline.groovy` already
resolves the registry from `PLATFORM_REGISTRY` and `buildImage.groovy` already
adds `registry.insecure=true` on the BuildKit push, so the library needs no
change. The address is a **node IP + NodePort**, not a Service DNS name,
because the same string is used by node-level containerd to pull the image
into the `demo-api` pod, and containerd cannot resolve cluster DNS. That makes
step 0 below mandatory.

**No cert-manager.** ingress-nginx serves its built-in self-signed
certificate. The browser warns once per host, then treats the page as a secure
context (which Backstage needs). That is the "self-signed cert" of wave 1; no
extra pods.

**Artifactory runs as the chart wants, not as the EKS Deployment did.** From
7.161.x the chart refuses `splitServicesToContainers: false`, so it is a
7-container StatefulSet + 2 small Deployments (frontend, jfbus) + PostgreSQL,
not one container on Derby. See the long comments in `values/artifactory.yaml`
for the memory reasoning. OSS limits, tried on 2026-10-16 (see Verified): generic and
Maven (a Maven remote cached `junit-4.13.2.pom` from Maven Central) work. The UI endpoint
will *create* PyPI, npm and Docker repository entries, but the PyPI index route
(`/artifactory/api/pypi/<repo>/simple/`) answers 404 and `pip download` finds no versions,
so do not rely on PyPI (or npm/Docker, untested beyond creation) on OSS.

**Argo CD is installed once, by hand, from the official manifest, and is not
managed by this tree.** An earlier draft of this directory also carried a Helm
install of Argo CD (`values/argocd.yaml`) and an optional Application to make it
self-managing; both were removed so there is exactly one install. A self-managing
Application for the *manifest* install would need its own kustomization over the
upstream `install.yaml` plus `homelab/argocd/ingress.yaml`, ignore the Secrets
Argo fills at runtime, and would restart the controller applying it; that is a
new, untested design, not a rename, so it was not kept.

## Sizing

**Measured 2026-10-16**, `kubectl top pods -A` / `kubectl top nodes` (metrics-server) on
the running cluster, ~25 min after the last full restart, so JVMs have had their warm-up
but not hours of load (Jenkins in particular grows; Prometheus holds under an hour of
data). Request/limit columns are what the pods actually declare (`kubectl get pods -o json`).

Budget: 3 VMs x 12225508 Ki = **35.0 GiB allocatable** (capacity == allocatable: the kubelet
reserves nothing, so this is also the ceiling the kernel will OOM against).

| Component | Measured | Memory request | Memory limit | PVC (local-path) |
|---|---|---|---|---|
| RKE2 itself (apiserver 792, canal 589, ingress-nginx x3 379, coredns 150, metrics-server, etcd, kube-proxy x3, controllers) | 2430 Mi | 3174 Mi | 320 Mi | - |
| Argo CD (controller 305, repo-server 135, server 123, dex 114, redis 30, notifications 26, applicationset 23: **7 pods, none declares requests or limits**) | 764 Mi | 0 | none | - |
| local-path-provisioner | 50 Mi | 32 Mi | 128 Mi | - |
| kube-prometheus-stack (Grafana 3 containers 510, Prometheus 357, operator 75, node-exporter x3 72, Alertmanager 56, KSM 18) | 1114 Mi | 1336 Mi | 2880 Mi | 8 + 1 + 1 Gi |
| registry | 52 Mi | 64 Mi | 256 Mi | 8 Gi |
| Jenkins controller + config-reload (idle) | 625 Mi | 1056 Mi | 2176 Mi | 8 Gi |
| Backstage | 293 Mi | 512 Mi | 1024 Mi | - |
| Artifactory OSS (artifactory-0 2916, frontend 196, jfbus 431, PostgreSQL 159) | 3707 Mi | 4672 Mi | 9472 Mi | 10 + 4 Gi |
| demo-api x2 (the deployed sample app) | 152 Mi | 128 Mi | 512 Mi | - |
| **Total** | **9187 Mi (9.0 GiB)** | 10974 Mi | 16768 Mi (+ unlimited Argo CD) | 40 Gi |

Nodes at the same moment (`kubectl top nodes`, working set, includes page cache the
pod numbers leave out): rke2-s1 3408 Mi (28%), rke2-a1 3944 Mi (33%), rke2-a2 5351 Mi
(44%) = **12.7 GiB of 35.0 GiB (36%)**. CPU 32-45% of 4 vCPU per node when idle; a2
sat at 66% while everything restarted at once.

Artifactory per container (`kubectl top pod -n artifactory --containers`; limit in
brackets): artifactory (core JVM) 1083 Mi [3 Gi], access 892 [1 Gi], jfconfig 508 [768],
topology 355 [512], jfbus 377 [512], PostgreSQL 159 [768], frontend 144 [384], router x3
38-41 [256], event 10 [512], metadata 17 [768], observability x3 12 [128].

What the measurement changed:

- **The estimates were too small where it mattered.** jfconfig was OOMKilled (137) on its
  first start with a 512 Mi limit and then ran at 508 Mi; the limit is now 768 Mi.
  access (892 of 1024 Mi) and topology (355 of 512) are close; a JVM sizes its heap from
  its limit, so high use is not proof of a need, but if either is OOMKilled raise it.
- **The earlier estimate was 8.1 GiB of requests for the platform alone** (helm-template
  sums). Declared requests for everything running are 10.7 GiB, of which RKE2's own pods
  ask for 3.1 GiB, and actual use is 9.0 GiB.
- **Argo CD is 764 Mi measured, not the 704 Mi "controller, server, repo-server, redis"
  guessed earlier**: the manifest install also runs dex, notifications and the
  ApplicationSet controller (the Helm values that switched them off were never in use),
  and none of the seven pods has requests or limits, so the scheduler sees them as free.
- **Build-agent pod, measured 2026-10-16** (python + buildkit + deploy + jnlp; 960 Mi
  requested, 2816 Mi of limits; transient, so not in the totals above). `demo-api` `main`
  build #2, `kubectl top pod -n jenkins --containers` every ~10 s (metrics-server refreshes
  about every 15 s, so a short spike can be missed): peak **jnlp 323 Mi, buildkit 68 Mi,
  deploy 43 Mi, python 7 Mi** (about 440 Mi together). Build #3, `memory.peak` read from
  each container's cgroup every 2 s (counts page cache, so it is the safer upper bound):
  **jnlp 344 Mi [limit 512], buildkit 304 Mi [1536], python 93 Mi [512], deploy 36 Mi [256]**,
  about 780 Mi together. The limits have room; the requests (buildkit 512 Mi) are generous
  rather than tight. A build takes about 2 minutes on these VMs (the first pull of the four
  images is slower).

Fit: 9.0 GiB used / 11.0 GiB requested / 16.4 GiB of limits against 35.0 GiB. Nothing had
to be cut. Two honest caveats remain:

- **Disk is the tighter budget, not RAM.** 40 Gi of PVCs plus the images (Artifactory +
  Jenkins + Prometheus + Backstage are several GiB each); local-path does not balance
  anything: a volume lands on the node its pod is first scheduled to. (The VMs' disks
  were later raised to 60 GiB; disk use was not measured here.)
- **Memory is spread unevenly.** a2 holds 5.3 GiB, s1 3.4 GiB, because the scheduler
  places by request and Argo CD declares none.

## Deploy

Prerequisites: the cluster is up and `kubectl` points at it; the VMs can reach
the internet (github.com, ghcr.io, docker.io, releases-docker.jfrog.io,
updates.jenkins.io, the chart repositories).

### 0. Let every node pull from the plain-http registry

Done by the cluster role, not by hand: `roles/rke2_cluster` writes
`/etc/rancher/rke2/registries.yaml` on every node from
`rke2_cluster_registry_mirrors` (default `10.77.0.31:30500`, http). On a running
cluster apply it with
`ansible-playbook -i homelab/generated/k8s.ini playbooks/rke2-registries.yml`
(one node at a time, agents first; see [`../README.md`](../README.md#3-vms-and-one-multi-node-rke2-cluster)).

Without it, builds succeed (BuildKit pushes with `registry.insecure=true`) and
the **deploy** stage fails with `ImagePullBackOff` / `http: server gave HTTP
response to HTTPS client`.

### 1. Argo CD (already installed)

One install, from the pinned official manifest, with its Ingress. The steps,
the tunnel and the way to read the initial admin password (straight to the
clipboard) are in [`../argocd/README.md`](../argocd/README.md).

### 2. Create the secrets (no secrets are in git)

Namespaces first, because the Secrets must exist before the charts start:

```bash
kubectl create ns jenkins; kubectl create ns observability; kubectl create ns artifactory

kubectl -n jenkins create secret generic jenkins-admin \
  --from-literal=jenkins-admin-user=admin \
  --from-literal=jenkins-admin-password="$(openssl rand -base64 18)"

kubectl -n observability create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 18)"

kubectl -n artifactory create secret generic artifactory-keys \
  --from-literal=master-key="$(openssl rand -hex 32)" \
  --from-literal=join-key="$(openssl rand -hex 32)"
ART_PW="$(openssl rand -base64 18)"
kubectl -n artifactory create secret generic artifactory-admin \
  --from-literal=password="$ART_PW" \
  --from-literal=bootstrap.creds="admin@*=$ART_PW"   # the pod reads THIS key (see values/artifactory.yaml)
kubectl -n artifactory create secret generic artifactory-postgresql \
  --from-literal=password="$(openssl rand -hex 16)" \
  --from-literal=postgres-password="$(openssl rand -hex 16)"
```

| Secret | Namespace | Keys | Read by |
|---|---|---|---|
| `jenkins-admin` | jenkins | `jenkins-admin-user`, `jenkins-admin-password` | Jenkins chart `controller.admin.existingSecret` |
| `grafana-admin` | observability | `admin-user`, `admin-password` | Grafana `admin.existingSecret` |
| `artifactory-keys` | artifactory | `master-key`, `join-key` | `masterKeySecretName` / `joinKeySecretName` |
| `artifactory-admin` | artifactory | `password`, `bootstrap.creds` | `artifactory.admin.secret` (+ `dataKey`) |
| `artifactory-postgresql` | artifactory | `password`, `postgres-password` | PostgreSQL subchart `auth.existingSecret`; the name is `<release>-postgresql`, which is where Artifactory reads the DB password |

**Or let a script do it with one password for every tool:** `HOMELAB_ADMIN_PASSWORD='...' homelab/platform/secrets.sh --apply`
(see [Run these yourself](../README.md#run-these-yourself)). It also sets `artifactory-admin`'s `bootstrap.creds` key
(`admin@*=<password>`), which is what `values/artifactory.yaml` reads (`dataKey: bootstrap.creds`); a Secret with only
`password` makes Artifactory's Access service die at bootstrap (see Verified, below).

Back these up somewhere outside the cluster if you care about the data: losing
`artifactory-keys` makes Artifactory's encrypted data unreadable. Read one back with e.g.
`kubectl -n jenkins get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d`.

**Why Argo does not fight them:** none of these Secrets is a rendered object
of any chart (each chart is told to use an existing Secret), so Argo never
sees them and there is nothing to diff or prune. Without that setting, the
Jenkins, Grafana and PostgreSQL charts would each generate a random password at
`helm template` time; Argo re-renders constantly, so the Secret would be
permanently OutOfSync and, worse, PostgreSQL's password would change under an
already-initialised database. The only `ignoreDifferences` in the directory is
in the optional self-managing Argo CD app (for `argocd-secret`, which the
server fills at runtime).

### 3. Hand over to git

```bash
kubectl apply -f homelab/platform/project.yaml -f homelab/platform/root.yaml
kubectl -n argocd get applications -w
```

The repository is public, so Argo CD reads it anonymously over HTTPS; no
repository credentials are configured. Argo reads `feat/playground` from
GitHub, so changes must be **pushed** to take effect.

Expect the first full sync to take 15-25 minutes, most of it Artifactory and
the Jenkins plugin download.

## Reaching it: from any device on the home Wi-Fi

Plain http, no certificate to trust, one login everywhere: user `admin`, the
password set by `secrets.sh` (`HOMELAB_ADMIN_PASSWORD`, never in git). The
user's decision (2026-10-16), knowing that logins then cross the Wi-Fi in
clear text and that anyone on it can reach every login page.

Verified 2026-10-16 from the Mac over the Wi-Fi, real nip.io DNS, real logins:

| Tool | URL | Page | Login check |
|---|---|---|---|
| Argo CD | http://argocd.192.168.1.153.nip.io | 200 | `POST /api/v1/session` 200; cookie without `Secure` |
| Grafana | http://grafana.192.168.1.153.nip.io | 200 | `/api/user` 200 |
| Jenkins | http://jenkins.192.168.1.153.nip.io | 200 | `/whoAmI` 200 (wrong password: 401) |
| Artifactory | http://artifactory.192.168.1.153.nip.io | 200 | `/api/repositories` 200 |
| Backstage | http://backstage.192.168.1.153.nip.io | 200 | guest (read-only) |
| Kubernetes API | https://192.168.1.153:6443 | — | `homelab/generated/rke2-lan.kubeconfig` (`homelab/mac/lan-kube-api.sh`) |

The Wi-Fi names are `manifests/lan-ingress/` (Argo CD app `lan-ingress`) and,
for Argo CD itself, `homelab/argocd/ingress.yaml`. The LAN IP is in those two
files only; the tools' browser-facing URLs (Grafana `root_url`, Backstage
`baseUrl`, Jenkins `jenkinsUrl`) follow the Wi-Fi names. Argo CD runs with
`server.insecure=true` (`homelab/argocd/argocd-cmd-params-cm.yaml`): without
it the login cookie is `Secure` and a plain-http browser loops on the login.

Prometheus and Alertmanager have **no Ingress** (neither authenticates):
`kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090`
(Alertmanager: `svc/kube-prometheus-stack-alertmanager 9093`). Grafana, which has a login, is the UI.

The old tunnel names (`ssh -N -L 8443:10.77.0.31:443 homelab-1-wsl`, then
`https://<tool>.127.0.0.1.nip.io:8443`) still route, but redirects and links now
point at the Wi-Fi names.

## Verified (2026-10-16)

On the live cluster, from the Mac, against `https://192.168.1.153/` (HAProxy -> ingress-nginx
hostPorts) with the tool's `Host` header, no credentials:

| Tool | Request | Status |
|---|---|---|
| Argo CD | `GET /` Host `argocd.127.0.0.1.nip.io` | 200 |
| Grafana | `GET /login` | 200 |
| Jenkins | `GET /login` | 200 |
| Artifactory | `GET /` / `GET /artifactory/api/system/ping` | 200 / 200 |
| Artifactory | `GET /artifactory/api/repositories` (no credentials) | 401 |
| Backstage | `GET /` / `GET /.backstage/health/v1/liveness` | 200 / 200 |
| Prometheus | `GET /` Host `prometheus.127.0.0.1.nip.io` | 404 (Ingress removed on purpose) |
| any | plain `http://` on :80 | 308 to https |

- **Argo CD:** `kubectl -n argocd get app` -> 9 of 9 `Synced` + `Healthy`, after the
  Application health check was applied (the root app showed `Degraded` while Artifactory was).
- **Prometheus:** `up{job="node-exporter"}` -> 3 series (10.77.0.31/.32/.33:9100), all 1; no
  target is `up==0` (apiserver, kubelet x9, coredns x2, KSM, Grafana, Alertmanager x2, ...).
- **Backstage:** with a guest token, `GET /api/catalog/entities` -> **22 entities** (7
  Component, 4 System, 3 Group, 3 Resource, 2 Location, 1 each API, Domain, Template), so the
  catalog URL in `values/backstage.yaml` was fetched from GitHub and parsed.
- **Memory:** the table under Sizing.

CI path, run 2026-10-16 from the Mac (Jenkins REST with crumb, `kubectl` on the LAN kubeconfig):

| Test | Evidence |
|---|---|
| **Jenkins `demo-api` `main` build** (Kubernetes agent, shared library, BuildKit push, deploy) | Build #2 (triggered with `POST /job/demo-api/job/main/build`): SUCCESS in about 2 min; stages Declarative: Checkout SCM, Test, Build image, Deploy, Declarative: Post Actions. Console: `pushed 10.77.0.31:30500/platform-lab/demo-api:main-488bac7e-2`, `kubectl -n demo-ci rollout status deployment/demo-api` ended `successfully rolled out`. Both `demo-api` pods Running with that image (rke2-a2 and rke2-s1, so containerd pulled it over plain http from the NodePort registry through the `registries.yaml` mirror). `port-forward` + GET `/` -> `{"app":"demo-api","version":"main-488bac7e-2"}`. Build #3 (re-run for the cgroup peaks) also SUCCESS. Agent memory: Sizing. |
| **Jenkins -> Artifactory** | Credential `artifactory-admin` (username/password, created with `POST /credentials/store/system/domain/_/createCredentials`) and job `artifactory-publish-test` (REST `createItem`; script in [`fixtures/artifactory-publish-test.Jenkinsfile`](fixtures/artifactory-publish-test.Jenkinsfile); runs on the library's `podtemplates/build.yaml`, container `deploy`). Build #1 SUCCESS: `upload HTTP 201`, `download HTTP 200`, `sha256 MATCH` (27d86279...1a46) against `http://artifactory.artifactory.svc.cluster.local:8082/artifactory/generic-local/jenkins/1.txt` (Service `artifactory`, ports 8082/8081); the password shows as `****` in the console; Artifactory's own `api/storage` reports the same sha256. The job and credential are **test fixtures and stay on the instance** (Jenkins keeps them on its PVC; they are not in JCasC). |
| **Artifactory OSS repo types** (UI endpoint `POST /ui/api/v1/ui/auth/login`, which needs `X-Requested-With: XMLHttpRequest` and an `Origin` header or it answers 403, then `POST /ui/api/v1/ui/admin/repositories` with `remoteRepoConfig`) | **Maven remote works**: `maven-remote` -> `https://repo1.maven.org/maven2`; GET `/artifactory/maven-remote/junit/junit/4.13.2/junit-4.13.2.pom` -> 200, 27018 bytes, cached in `maven-remote-cache` (sha256 569b6977...d94). **PyPI remote is created (200) but unusable**: `/artifactory/api/pypi/pypi-remote/simple/requests/` -> 404 (also without the trailing slash and `/simple/`), and `pip download requests==2.32.3 --no-deps -i http://admin:***@artifactory.192.168.1.153.nip.io/artifactory/api/pypi/pypi-remote/simple` -> "Could not find a version ... (from versions: none)"; the pod reaches pypi.org (200), so it is the OSS build not serving the PyPI API. npm, Docker (local and remote) entries were also accepted at creation (200); Docker `/v2` and npm `/api/npm` routes answered 404 / 401 and nothing was pushed. Repo delete is Pro-only. |
- **Artifactory's root cause** (two parts; both fixed in git):
  1. `artifactory.admin.dataKey: password` made the chart mount the bare password as Access'
     `bootstrap.creds`, which must be `admin@*=<password>`. Access died at bootstrap
     ("Illegal credentials file - each line is expected to be in the format: user=pass"),
     never wrote the join key, and every other container waited on it (router: "Join key is
     missing") until the startup probes killed it. Fixed by a `bootstrap.creds` key in the
     Secret and `dataKey: bootstrap.creds`.
  2. jfconfig was OOMKilled at 512 Mi (limit now 768 Mi).
  After the fix `artifactory-0` reached 8/8 about 13 minutes after the pod started. Expect
  that on every pod start: the core container starts before Access has written the join key,
  fails once ("Failed resolving join key"), and is restarted by its startup probe, so a start
  shows 4-6 restarts and takes 10-15 minutes on three busy VMs. That is the chart's
  start-up ordering, not a fault.
- **After a WSL restart** (the Windows Update of WSL stopped the lab): nothing was broken
  persistently. The VMs cold-booted (about 3 minutes), all pods restarted at once, and
  `https://192.168.1.153/` timed out or returned 503 until each node's ingress-nginx and the
  app behind it were Ready. HAProxy log: started 21:57:22, all 3 backends DOWN, rke2-s1 UP
  21:58:09, rke2-a2 22:00:35, rke2-a1 22:00:51. The CNI hostPort rules
  (`CNI-HOSTPORT-DNAT` for :80/:443) were present on all three nodes, `iptables` is installed,
  and there were no sandbox/portmap events, so the earlier leaked-IP failure did not recur.
  Budget about 4 minutes after the VMs start for the front door and 10-15 for Artifactory.
  HAProxy's check is layer 4 (it cannot see "backend app not Ready"), so during that window
  it forwards to nodes whose ingress answers 503.

## Not verified yet

Done earlier (static only): the YAML parses and passes `yamllint`; `helm template`
succeeds for every chart at its pin; every `$values/...` path and `path:` in `apps/` resolves.

Not done:
- Artifactory OSS **Docker and npm** repositories were only *created* through the UI endpoint
  (accepted); nothing was pushed or pulled. PyPI was tried and does not work (see Verified).
  OSS cannot delete repositories (`DELETE /artifactory/api/repositories/<key>` and the UI delete
  route both answer "available only in Artifactory Pro"), so the probe repos `pypi-remote`,
  `npm-remote`, `docker-remote` and `docker-probe` are still there as inert config entries.
- **Backstage over https**: the http-only workarounds are kept on the strength of their own
  comments; the Kubernetes tab, the shared-library link and TechDocs were not opened in a browser.
- The pipeline only deploys on branch `main`; a failing build's auto-rollback was not
  exercised in this pass.
- RKE2's `kube-controller-manager`, scheduler, etcd and kube-proxy scrapes are switched off
  in kube-prometheus-stack (they bind to localhost on RKE2).
- The 8443 SSH-tunnel path was not re-tested in this pass (the LAN path was).
- Pod pulls need working internet from the VMs; none of the images are mirrored.
