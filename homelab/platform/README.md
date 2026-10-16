# Home-lab platform (Argo CD app-of-apps)

The on-prem counterpart of `gitops/platform/` + `ci/`: the same tools (Jenkins,
Artifactory, Backstage, kube-prometheus-stack), declared as Argo CD
Applications for the **RKE2 cluster on the Incus VMs** (`rke2-s1` 10.77.0.31,
`rke2-a1` .32, `rke2-a2` .33), reusing the EKS work instead of redoing it.

> **Status: authored, statically validated, NOT deployed.** See
> [Not verified yet](#not-verified-yet) before trusting any of it.

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
starting the next:

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
for the memory reasoning. OSS limits: no Docker repos; generic and the Maven
family are what it is for. **PyPI I could not confirm for OSS (I believe it is
Pro-only)** -- check in the UI before relying on it.

**Argo CD is installed once, by hand, from the official manifest, and is not
managed by this tree.** An earlier draft of this directory also carried a Helm
install of Argo CD (`values/argocd.yaml`) and an optional Application to make it
self-managing; both were removed so there is exactly one install. A self-managing
Application for the *manifest* install would need its own kustomization over the
upstream `install.yaml` plus `homelab/argocd/ingress.yaml`, ignore the Secrets
Argo fills at runtime, and would restart the controller applying it; that is a
new, untested design, not a rename, so it was not kept.

## Sizing

Budget: 3 nodes x 12 GiB = 36 GiB; ~2 GiB per node for RKE2 itself (kubelet,
containerd, etcd, canal, rke2-ingress-nginx, coredns, metrics) -> **~30 GiB
allocatable**. Figures are summed from the `helm template` output of the exact
values in this directory (node-exporter counted x3).

| Component | Memory request | Memory limit | CPU request | PVC (local-path) |
|---|---|---|---|---|
| local-path-provisioner | 32 Mi | 128 Mi | 0.01 | - |
| Argo CD (controller, server, repo-server, redis) | 704 Mi | 1920 Mi | 0.38 | - |
| kube-prometheus-stack (Prometheus 768Mi, Grafana, Alertmanager, operator, KSM, node-exporter x3) | 1336 Mi | 2880 Mi | 0.36 | 8 + 1 + 1 Gi |
| registry | 64 Mi | 256 Mi | 0.03 | 8 Gi |
| Jenkins controller (+ config-reload) | 1056 Mi | 2176 Mi | 0.26 | 8 Gi |
| Artifactory OSS (7 containers + frontend + jfbus + PostgreSQL) | 4544 Mi | 9216 Mi | 2.08 | 10 + 4 Gi |
| Backstage | 512 Mi | 1024 Mi | 0.10 | - |
| **Steady state** | **8248 Mi (8.1 GiB)** | **17600 Mi (17.2 GiB)** | **3.2** | **40 Gi** |
| One build's agent pod (python + buildkit + deploy + jnlp), transient | 960 Mi | 2816 Mi | ~0.5 | - |
| **Steady state + one build** | **9.0 GiB** | **19.9 GiB** | **3.7** | |

Fit: requests are 9.0 of ~30 GiB (30%), and limits (a ceiling, not an
expectation) are 19.9 of ~30 GiB (66%). The largest single pod is Artifactory's
at ~3.4 GiB requested / 6.6 GiB of limits, which fits on any one node. Nothing
had to be cut. What I did trim relative to chart defaults: dex, notifications
and the ApplicationSet controller in Argo CD (off), the kube-prometheus-stack
control-plane scrapes (off, see the file), Prometheus retention 7d/6GB, and the
Artifactory PostgreSQL volume (chart default is 200 Gi; here 4 Gi).

Two honest caveats:

- **If the VMs are not resized and stay 8 GiB** (~18 GiB allocatable), requests
  still fit (9.0 GiB) but limits overcommit (19.9 GiB); a bad day with
  Artifactory, Prometheus and a build all at their ceilings would OOM-kill
  something. Resize to 12 GiB.
- **Disk is the tighter budget, not RAM.** 40 Gi of PVCs plus the images
  (Artifactory + Jenkins + Prometheus + Backstage are several GiB each) on
  3 x 40 GiB disks only works if local-path spreads the volumes, and it does not
  balance anything: a volume lands on the node its pod is first scheduled to.
  If you can, give each VM 60 GiB.
- The Artifactory per-container numbers are **estimates** derived from the EKS
  experience, not measured on the split layout. Run
  `kubectl top pod --containers -n artifactory` after first start.

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
kubectl -n artifactory create secret generic artifactory-admin \
  --from-literal=password="$(openssl rand -base64 18)"
kubectl -n artifactory create secret generic artifactory-postgresql \
  --from-literal=password="$(openssl rand -hex 16)" \
  --from-literal=postgres-password="$(openssl rand -hex 16)"
```

| Secret | Namespace | Keys | Read by |
|---|---|---|---|
| `jenkins-admin` | jenkins | `jenkins-admin-user`, `jenkins-admin-password` | Jenkins chart `controller.admin.existingSecret` |
| `grafana-admin` | observability | `admin-user`, `admin-password` | Grafana `admin.existingSecret` |
| `artifactory-keys` | artifactory | `master-key`, `join-key` | `masterKeySecretName` / `joinKeySecretName` |
| `artifactory-admin` | artifactory | `password` | `artifactory.admin.secret` (+ `dataKey`) |
| `artifactory-postgresql` | artifactory | `password`, `postgres-password` | PostgreSQL subchart `auth.existingSecret`; the name is `<release>-postgresql`, which is where Artifactory reads the DB password |

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

## Reaching it from the Mac

```bash
ssh -N -L 8443:10.77.0.31:443 homelab-1-wsl
```

All hostnames are `<tool>.127.0.0.1.nip.io` (nip.io resolves them to
127.0.0.1, i.e. the tunnel's local end; ingress-nginx routes by `Host`). The
browser will warn about the self-signed certificate once per host.

| Tool | URL | Login |
|---|---|---|
| Argo CD | https://argocd.127.0.0.1.nip.io:8443 | `admin` / `argocd-initial-admin-secret` |
| Grafana | https://grafana.127.0.0.1.nip.io:8443 | secret `grafana-admin` |
| Prometheus | https://prometheus.127.0.0.1.nip.io:8443 | none (see below) |
| Jenkins | https://jenkins.127.0.0.1.nip.io:8443 | secret `jenkins-admin` |
| Artifactory | https://artifactory.127.0.0.1.nip.io:8443 | `admin` / secret `artifactory-admin` |
| Backstage | https://backstage.127.0.0.1.nip.io:8443 | guest sign-in |

Prometheus has no authentication; it is reachable only through the tunnel.
Alertmanager has no Ingress (`kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093`).
The tools' own external URLs include `:8443` (Jenkins `jenkinsUrl`, Grafana
`root_url`, Backstage `baseUrl`), so if you change the tunnel's local port,
change those too.

## Not verified yet

Nothing here has run against a cluster.

Done (static only):
- All 21 YAML files parse and pass `yamllint` with the repo's `.yamllint`.
- `helm template` succeeds for every chart at its pinned version with the exact
  values in `values/` (Argo CD, local-path-provisioner at v0.0.37, kube-prometheus-stack,
  Jenkins, Artifactory OSS, Backstage). That proves the values keys exist and the
  templates render, nothing more.
- Every `$values/...` path and every `path:` in `apps/` resolves in the repo.

Not done, and likely to bite:
- No Application has been synced; the `AppProject` is deliberately permissive
  on resource kinds because the exact set is unknown.
- **The registry path end to end** (BuildKit push to `10.77.0.31:30500`,
  containerd pull via the `registries.yaml` mirror) is untested, and depends on
  the nodes being configured as in step 0.
- **Artifactory** may still not start: per-container memory is estimated, and
  the split-container chart plus PostgreSQL was never run by me (the previous
  successes were the single-container image). Whether OSS offers PyPI is unconfirmed.
- **Backstage over https**: the EKS file's http-only workarounds were removed on
  the strength of its own comments, not on a test. Fallback is described at the top of `values/backstage.yaml`.
- **The `HelmChartConfig`** assumes the cluster builder did not already ship one
  for `rke2-ingress-nginx`; if it did, delete `apps/10-ingress-nginx-config.yaml`.
- Jenkins' `kubernetes` cloud, the shared library from `feat/playground`, and the
  multibranch scan have not been exercised. The pipeline only builds/pushes/deploys
  on branch `main` (`deployBranch`), so seeing a deploy needs a build of `main`.
- RKE2's `kube-controller-manager`, scheduler, etcd and kube-proxy scrapes are
  switched off in kube-prometheus-stack (they bind to localhost on RKE2).
- Pod pulls need working internet from the VMs; none of the images are mirrored.
