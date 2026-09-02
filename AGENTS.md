# AGENTS.md — instructions for an AI assistant working on this repo

Read this before doing anything. It encodes an afternoon of failures against a
real KodeKloud AWS playground on 2026-08-18, so you do not repeat them.

**Everything below was verified live.** Where a claim is unverified it says so.

---

## 0b. Published artifacts

Two write-ups exist for this work. **Update them rather than minting new ones**
— republishing the same URL keeps the link stable:

- Architecture: <https://claude.ai/code/artifact/33a25fb7-fda8-46b5-a4ce-b1cb09a33130>
- GitOps delivery styles: <https://claude.ai/code/artifact/3bbe06ac-2659-4c85-8f3d-b80bc518dda4>

Pass the URL as the `url` parameter when publishing from a new conversation,
otherwise a fresh URL is created and the shared link goes stale.

## 1. What this repo is

A lab that builds, with Terraform + Ansible:

- a 3-node **Elasticsearch** cluster (+ Kibana, MinIO for snapshots)
- **PostgreSQL** on EC2 **and** on RDS, for comparison
- **k3s** running Kong (API gateway) and Keycloak (OIDC)
- **RKE2** running Rancher — a second distribution, on purpose
- an **EKS** control plane, in a separate root module

The deliverable is not the stack. It is `drills/01`–`17`: each has a "say this
in the interview" section, and drills 09–17 are write-ups of bugs hit here.

---

## 2. Start of every session: get credentials

The playground gives console credentials. Two ways to get API access:

```bash
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=us-east-1
```

Get those from the console: sign in with the credentials the playground gives
you, then **IAM -> Users -> <your kk_labs_user> -> Security credentials ->
Create access key -> CLI**.

### `aws login` does NOT work here (verified twice, two different accounts)

`scripts/aws-lab-env.sh` wraps `aws login`, the AWS CLI's browser flow that
exchanges a console session for temporary API credentials. It is the nicer path
because it creates no long-lived key -- and the KodeKloud playground **rejects
it**:

```
Authentication failed
Invalid request
```

The flow needs console-to-CLI federation, which the playground's boundary policy
does not grant to its IAM users. The script is kept for real AWS accounts, where
it works; in the playground, go straight to an access key and do not spend
session time on it.

**Never write lab credentials into `~/.aws/credentials`.** Users of this repo
often have production profiles there. Keep them in the environment or a
throwaway file with mode `600`.

**Check which account you are in before every apply.** `scripts/tf-init.sh`
prints the account and refuses to continue without confirmation; set
`LAB_ACCOUNT_IDS=<id>` to skip the prompt once you have verified it.

### The IAM window is time-boxed — this WILL bite you

Every statement in the playground's boundary policy carries:

```json
"DateGreaterThan": {"aws:CurrentTime": "...T09:24:03Z"},
"DateLessThan":    {"aws:CurrentTime": "...T12:24:03Z"}
```

Three hours from session start, enforced in IAM. When it closes, AWS API calls
return AccessDenied **while the instances keep running**. A late failure is
often the clock, not the config. Check remaining time:

```bash
aws iam get-policy-version --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWS_EKSECSWithConditions \
  --version-id v1 --query 'PolicyVersion.Document' | grep CurrentTime
```

**Plan around it:** do everything requiring the AWS API (Terraform) first.
Ansible runs over SSH and has no deadline — it keeps working after the window
closes.

---

## 2b. Entry point

`make help` lists everything. It fronts the scripts rather than replacing them,
and it is Make as a *task runner*, not a build system — nothing here produces
files. `just`/Taskfile are more honest about that distinction; Make is used
because it is on every machine and needs no install.

## 3. Build order

```bash
# 1. state bucket + backend (see drills/10)
./scripts/tf-init.sh

# 2. infrastructure
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
#    my_ip_cidr = "$(curl -4 -s ifconfig.me)/32"      <- -4 MATTERS, see section 6
terraform apply            # writes inventory/hosts.ini itself

# 3. secrets  (NOTE THE all/ DIRECTORY -- see drills/16)
ansible-vault create inventory/group_vars/all/vault.yml
#   minio_root_password / postgres_app_password
#   rancher_bootstrap_password / keycloak_admin_password
ansible all -m debug -a "msg={{ minio_root_password }}" --ask-vault-pass   # VERIFY IT LOADED

# 4. configuration
ansible-playbook playbooks/elastic.yml --ask-vault-pass
ansible-playbook playbooks/k8s.yml --limit k3s-01  --ask-vault-pass -e rancher_enabled=false
ansible-playbook playbooks/k8s.yml --limit rke2-01 --ask-vault-pass -e kong_enabled=false -e kong_oidc_enabled=false

# 5. RDS — password comes from Terraform state, never a file
ansible-playbook playbooks/rds.yml --ask-vault-pass \
  -e rds_master_password="$(terraform -chdir=terraform/aws output -raw rds_password)"

# 6. Rancher imports the k3s cluster -- THE demo (see drills/07)
ansible-playbook playbooks/rancher-import.yml --ask-vault-pass
```

**Install Rancher EARLY in the session.** It needs sustained CPU, and a
`t3.medium` in `standard` credit mode is throttled to ~20% baseline once its
launch credits are gone. Rancher took 9 minutes to start on a credit-exhausted
node and needed its startup probe widened to survive. See drills/17.

### Where each component goes, and why

Do not co-locate Rancher and Keycloak — they do not fit on 4 GiB together.

| node | runs |
|---|---|
| es-01/02/03 | Elasticsearch (+ Kibana, MinIO, Postgres on es-01) |
| k3s-01 | k3s, Kong, Keycloak |
| rke2-01 | RKE2, cert-manager, Rancher |

es-01 is the tight one: Elasticsearch sizes its heap to half of RAM without
knowing it shares the box. Cap it:

```yaml
# inventory/host_vars/es-01.yml
elastic_heap_mb: 1200        # frees ~700 MB
```

Add `--private-key ~/.ssh/id_ed25519` if your key is not the default.

---

## 4. Capacity — the constraint that shapes everything

**5 instances maximum.** 3 ES + k3s + RKE2 = exactly 5. Nothing else fits.

**Every node is `t3.medium`: 2 vCPU / 4 GiB, `standard` CPU credits.**
`unlimited` mode **suspends the session** — never set it.

Measured, mid-session:

| node | carrying | result |
|---|---|---|
| es-01 | Elasticsearch 2365 MB + Kibana 509 MB + MinIO 100 MB + Postgres | **259 MB free** |
| k3s-01 | k3s + Kong + Keycloak + Rancher | **wedged, needed a reboot** |
| rke2-01 | RKE2 + Rancher | 1.9 GB free, **82% CPU steal** |

Use the toggles rather than hoping:

| toggle | where | frees |
|---|---|---|
| `kibana_enabled=false` | Ansible | ~509 MB on es-01 (verified 259→754 MB) |
| `minio_enabled=false` | Ansible | ~100 MB |
| `postgres_enabled=false` | Ansible | redundant once RDS exists |
| `rancher_enabled=false` | Ansible | ~1.5 GB |
| `kong_enabled=false` | Ansible | ~500 MB |
| `kong_oidc_enabled=false` | Ansible | ~1 GB (Keycloak) |
| `create_rds=false` | Terraform | saves 6-10 min of apply |
| `create_rancher_node=false` | Terraform | frees an instance |
| `data_volume_gb=0` | Terraform | skips the EBS volumes |

The Ansible toggles **stop running services**, not just skip installation.

**Rancher and Keycloak do not fit on one node.** Run Rancher on rke2-01 and
Keycloak on k3s-01. That is why `create_rancher_node` exists.

---

## 4b. The GitOps track (Argo CD + Flux)

Independent of the Elasticsearch lab. Needs a Kubernetes cluster and nothing
else — it has run unchanged on both k3s and EKS.

```bash
./scripts/eks-up.sh          # THREE-PHASE build -- see 4c, do not skip it
./scripts/gitops-install.sh  # Argo CD + Flux, both reconciling this repo
./scripts/gitops-addons.sh   # ingress-nginx, Rollouts, Flagger, sealed-secrets,
                             # flux-operator -- the layer that needed the pod fix
./scripts/scenario list
```

`gitops-install.sh` now refuses to run if a node reports 17 allocatable pods,
because everything downstream fails in a way that points nowhere near the cause.

**One hard version floor:** Flux v2.9 requires **Kubernetes >= 1.33**. That is
why `terraform/eks` and the k3s role are pinned to 1.33. Argo CD is far more
relaxed — Flux is the binding constraint. Argo CD v3.5.1 must be installed with
`--server-side --force-conflicts` (its CRDs exceed the client-side apply limit).

**Two Argo CD traps already paid for:**

- `clusterResourceWhitelist: []` in an AppProject silently forbids
  `CreateNamespace=true` — a Namespace IS cluster-scoped. The Application sits
  `OutOfSync/Missing` forever and the reason is in `status.operationState`, not
  in conditions. Allow exactly `Namespace`.
- A project whose `destinations` include the `argocd` namespace is effectively
  cluster admin.

**Writing scenarios** (`gitops/scenarios/NN-name/run.sh`, three bash functions):
never suppress the output of the thing whose failure you are testing — scenario
02 hid a rejected patch and reported "Healthy" for 96 seconds — and never let a
test harness rewrite git history.

## 4c. Progressive delivery (canary / blue-green) -- all measured

**Neither Argo CD nor Flux does this.** Both stop at "apply the manifests" —
what you get is a Kubernetes RollingUpdate with no traffic weighting, no metric
gates and no automatic rollback. Scenario 05 measures exactly what that costs.

It needs a SEPARATE controller: **Argo Rollouts** (Argo side) or **Flagger**
(Flux side). Manifests live in `gitops/progressive/`.

### Argo Rollouts — two safety nets, each blind to the other's failure

`gitops/progressive/rollouts-nginx/`, scenario 06. Measured on EKS v1.33:

| failure | caught by | how long |
|---|---|---|
| broken image, never becomes ready | `progressDeadlineAbort: true` | 80–131s |
| healthy but too slow (SLO breach) | the `AnalysisTemplate` | 30–50s |

The ranges are honest: `progressDeadlineSeconds` is 120 and the observed abort
lands a reconcile either side of it. Do not quote a single figure.

**And the deadline only behaves that way on a ReplicaSet the rollout has not
seen before.** Argo Rollouts keys a ReplicaSet by pod-template hash, so
re-shipping a template it already has REUSES the old one — and a reused
ReplicaSet did **not** abort at all:

| | broken image |
|---|---|
| fresh ReplicaSet | Degraded at **t+131s** |
| ReplicaSet reused from an earlier run | still `Progressing` at **t+420s** |

Same cluster, same manifests, same `Healthy` baseline. This is why
`scenario_reset` in scenario 06 deletes every zero-scaled ReplicaSet rather than
just running `undo` — without that, a second run measures a dirty baseline and
reads as `progressDeadlineAbort` being unreliable. `revisionHistoryLimit: 2`
does not save you; two is already enough to hit the reuse.

**`progressDeadlineAbort` is the line that was missing.** Without it,
`progressDeadlineSeconds` only *marks* the rollout Degraded and leaves the canary
in place — which is what produced the earlier "blast radius capped at 25%, but no
rollback".

**And analysis genuinely cannot see the broken-image case, even with traffic
routing.** Argo Rollouts only re-points the canary Service at the new ReplicaSet
once that ReplicaSet has an *available pod*, so a canary in `ImagePullBackOff`
leaves both Services on the stable hash:

```
$ kubectl get svc podinfo-canary -o jsonpath='{.spec.selector}'
{"app":"podinfo","rollouts-pod-template-hash":"86d9ccdc4d"}   <- stable's hash
```

The `AnalysisRun` reports `Successful`, correctly — there is no canary to
measure. So the two mechanisms are not redundant, and a rollout configured with
only one has a blind spot.

The earlier "analysis trap" in `gitops/progressive/rollouts/` is kept
deliberately: it curls the one Service selecting all four pods, so a broken
canary is missed 75% of the time.

### Flagger — metric-driven, and it needs two things nobody mentions

`gitops/progressive/flagger/`, scenario 07. Measured:

- good release: `Progressing` 10→50 by stepWeight, `Promoting`, `Finalising`,
  **`Succeeded` in 150s**
- bad release: weight never advanced past 10, `failedChecks` 1→5,
  **`Failed` and rolled back at t+90s** — on metrics alone, with no
  AnalysisTemplate written anywhere

Both of these produce the *same* misleading error, and neither is a Flagger fault:

```
Halt advancement no values found for nginx metric request-success-rate
probably podinfo.demo-flagger is not receiving traffic
```

1. **ingress-nginx ships with `controller.metrics.enabled=false`.** No
   `nginx_ingress_controller_requests` series ever exists. Flagger's bundled
   Prometheus also needs `prometheus.io/scrape` pod annotations to find it.
2. **The load-test webhook must go through the ingress**, with the Host header
   the Ingress matches. Pointing `hey` at the Service generates plenty of real
   traffic that nginx never counts.

**Experiment hygiene, learned the hard way:** `request-success-rate` is a *rate
over the last minute of namespace-wide counters*. A `hey ... /status/500` left
running from a previous test makes the next good release fail at "success rate
36.89% < 99%" while every manual curl returns 200. Scenario 07 now kills stray
load and waits out the rate window before measuring.

### A/B testing is NOT an Argo Rollouts feature on nginx

`gitops/progressive/ab-testing/`, scenario 08. `setHeaderRoute` is rejected at
admission:

```
spec.strategy.steps[1].setHeaderRoute: Invalid value: {...}:
SetHeaderRoute requires TrafficRouting, supports Istio and ALB and Apisix
```

The Rollout goes to `Degraded` with **zero replicas** — no pod is ever created.
Note `trafficRouting.nginx` **is** supported for weighted canaries (scenario 06
relies on it); header and mirror routing are the exclusions. ALB would work, but
the AWS Load Balancer Controller needs IRSA and `iam:CreateRole` here is
restricted to three exact role names.

Rebuilt on ingress-nginx's own annotations — two Ingresses, **same host and
path**, one marked canary. Measured, 20 requests each:

| request | result |
|---|---|
| no header | 20 A / 0 B |
| `X-Cohort: beta` | 0 A / **20 B** |
| `X-Cohort: control` | 20 A / 0 B |
| `Cookie: ab-cohort=always` | 0 A / **20 B** |

At `canary-weight: 0` throughout — nginx evaluates header and cookie matches
**before** weight, and that precedence is what makes A/B possible rather than
just a canary.

## 4d. Helm, secrets, webhooks, Flux Operator

**Helm** (`gitops/helm/`, scenario 10). Both "support Helm"; only one runs it.
Release Secrets in the namespace: **Flux 1, Argo CD 0** — Argo CD runs
`helm template` and applies the YAML, so `helm list` is empty and `helm rollback`
does not exist.

Drift on the chart's Deployment, `kubectl scale --replicas=5`:

| | result |
|---|---|
| Argo CD | back to 2 in **10s** (selfHeal, event-driven) |
| Flux, `driftDetection` unset — **the default** | still 5 after **180s**, `Ready=True reason=InstallSucceeded` |
| Flux, `driftDetection.mode: enabled` | corrected in ~20s at `interval: 1m` |

Two separate gaps: it is **off by default**, and when on it runs on the
**reconcile interval** rather than a watch. `Ready` describes the last
`helm upgrade`, not whether the cluster matches the chart.

**Secrets** (`gitops/secrets/`, scenario 09). Both sealed-secrets and SOPS+age,
because they fail differently. The `SealedSecret` unseals in `demo-secrets` and
is **refused** in another namespace (`no key could decrypt secret`) — the
namespace is inside the envelope. SOPS keeps the manifest structure readable in
a diff; a `SealedSecret` diff is one opaque blob. **A rebuilt cluster generates a
new sealing key, so every committed `SealedSecret` is dead** unless you backed
the key up. Regenerate with `scripts/secrets-seal.sh`.

**Argo CD webhook** (`scripts/argocd-webhook.sh`, scenario 11). It *does* work on
a playground. Verified with a signed payload: **HTTP 200, both Applications
refreshed immediately**, against ~155s of polling.

- **Use the HTTPS NodePort, not HTTP.** argocd-server answers HTTP with a **307**,
  and GitHub does not follow redirects for webhook delivery — the hook reads as
  delivered and Argo CD never hears about it. Measured: 307 on :30083, 200 on
  :30084.
- The self-signed cert means `insecure_ssl=1`, so the HMAC is doing all the
  actual work. Set `webhook.github.secret`; argocd-server caches it and re-reads
  on restart.
- Sign the test payload in python, not `openssl dgst`: the signed bytes and the
  sent bytes must be identical, and shell quoting of JSON breaks that.
- Registering the hook needs `gh` or two clicks — this laptop has neither `gh`
  nor an HTTPS token (the remote is SSH), so that last step is manual.

**Flux Operator** (`gitops/flux-operator/`, scenario 12). Its UI is on NodePort
**30086** — and note the asymmetry with Argo CD: **it has no authentication at
all**, answering 200 with no `WWW-Authenticate` header. Read-only, but it shows
everything the cluster runs. Fine for a three-hour lab, wrong anywhere else;
drop `flux-ui` from `node_service_ports` and port-forward instead.

Adopted a live `flux install` in **12s** without disturbing either Kustomization, and its
`kustomize.patches` reached the controllers. **Flux does have a web UI** — the
operator serves it on port **9080** (`http-web`), `<title>Flux Status</title>`.
AGPL-3.0, which is a procurement question rather than a technical one.

Worth knowing before handing over: installing the operator does **not** take over
an existing `flux-system`. Until a `FluxInstance` exists it only *observes*,
publishing a `FluxReport` that inventories whatever is already running.

### The EKS limit that blocked it: pods per node, not CPU -- SOLVED

```
0/2 nodes are available: 2 Too many pods
cpu 680m (35%)        <- plenty of CPU free
max_pods/node: 17
```

Every EKS pod takes a **real VPC IP from an ENI**, so pod density is capped by
instance type. A `t3.medium` allows **17 pods** however idle the CPU is. Argo CD
(7) + Flux (5) + Rollouts + ingress-nginx + Flagger + Prometheus exhausts three
nodes. **This is invisible on k3s**, which uses an overlay network.

**`./scripts/eks-up.sh` fixes it. Use that, not `terraform apply` directly.**
Verified 2026-08-20: **110 allocatable pods per node, and 58 pods running with
0 Pending** — which does not fit under the old ceiling.

Two halves are required and only one of them is well known:

1. `ENABLE_PREFIX_DELEGATION=true` on the `aws-node` daemonset, so the CNI hands
   out /28 prefixes instead of single IPs.
2. **kubelet's `--max-pods`, pinned in the nodeadm config.** nodeadm computes 17
   from the instance type at bootstrap and kubelet reads it once. Flip only the
   daemonset and the node keeps advertising 17 forever — verified.

And the ordering is load-bearing: the daemonset must already carry the env var
*before a node joins*. `eks-up.sh` therefore runs three phases — cluster with the
ASG at zero, patch the CNI, then scale up.

**"Use a bigger instance" is not available here.** An organization SCP denies
`ec2:RunInstances` for every type except `t3.medium`:

```
is not authorized to perform: ec2:RunInstances ... with an explicit deny in a
service control policy: p-3m2d0vav
```

t3.large, t3.xlarge and m5.large were all refused. Prefix delegation is the only
route, not a preference.

### The bug this introduced, which cost 20 minutes

The nodeadm document was a `<<-MIME` heredoc with `%{if}` around the kubelet
block. `<<-` strips the smallest common indent across **all** lines, and a
`%{if}` marker line participates in that calculation while contributing no
output. Result:

```yaml
    cidr: 10.100.0.0/16
      kubelet:          # 6 spaces
    config:             # 4 spaces
```

Three EC2 instances ran for 20 minutes and never registered. **Nothing reports
this** — EC2 says the launch succeeded, the ASG says Healthy, and the cluster
simply has no nodes. It is now built with `yamlencode`, which cannot emit
misindented YAML. Reach for `yamlencode` whenever generated YAML is
indentation-sensitive.

## 4e. The platform layer under GitOps, and the Argo CD behaviour it exposed

`gitops/platform/` is an app-of-apps: ingress-nginx, Prometheus/Grafana, APISIX,
etcd and the StorageClass are **Argo CD Applications**, not shell scripts. Before
it existed the repo reconciled its *workloads* with GitOps and installed its
*platform* with `helm` from a script somebody ran by hand — which fails the
obvious question, *"you say GitOps, what reconciles your platform?"*

```bash
./scripts/eks-up.sh          # four phases now -- prefix delegation AND storage
./scripts/gitops-install.sh
./scripts/apisix-bootstrap-secret.sh
kubectl apply -f gitops/platform/project.yaml -f gitops/platform/root.yaml
```

**Owned by Argo CD alone.** Two controllers reconciling one Helm release fight,
each reading the other's writes as drift. The Argo-vs-Flux comparison stays at
the workload layer where the namespaces are disjoint.

### Argo CD facts this cost time to learn

| | |
|---|---|
| **Argo CD never runs `helm install`** | It runs `helm template` and applies. No release Secret is created or read, so "adopting a release" is not a thing — it manages the same *objects* while the old release Secret sits ignored, a latent hazard if someone later runs `helm upgrade` |
| **`helm.releaseName` is a template variable** | It sets `.Release.Name`, defaulting to the *Application* name. Charts build resource NAMES from it, so omitting it renders a parallel set of objects (`platform-apisix-*` beside `apisix-*`). The symptom is `OutOfSync`/**`Missing`**, not a conflict |
| **`ServerSideApply=true` silently selects a discontinued diff strategy** | It enables Structured-Merge Diff, which the docs mark *Feature Discontinued* for "challenges calculating diffs for CRDs that define default values". Measured: 15 of 16 differing fields were server-side defaults. Pair it with **`ServerSideDiff=true`** |
| **`ignoreDifferences` does not stop writes** | It affects the diff only; "during the sync stage, the desired state is applied as-is". Add **`RespectIgnoreDifferences=true`** or Argo CD keeps writing the field it stopped reporting |
| **`ignoreDifferences` does not resolve ownership either** | Two Applications claiming one object still both write. **`FailOnSharedResource=true`** is the documented circuit-breaker; it fails the sync rather than deciding an owner |
| **There is no Application-level "exclude one resource"** | If a chart templates something you must own elsewhere, the options are kustomize `helmCharts` inflation with `$patch: delete`, a post-renderer, or a chart value that disables it |
| **Helm hooks: every operation is a sync** | `pre-install` and `pre-upgrade` both map to `PreSync` and Argo CD cannot tell an install from an upgrade, so **pre-upgrade hooks run on fresh installs** |
| **`Healthy` ≠ "git got applied"** | An Application read `Healthy` through five consecutive failed syncs. `Healthy` means what exists is working, not that what git asked for exists |

### The deadlock, and the churn — both worth being able to describe

**Deadlock.** APISIX's bundled etcd ships a `pre-upgrade` hook. On a fresh
install Argo CD runs it anyway (see above), it mounts a Secret the *main sync*
creates, and the main sync is blocked waiting for the hook. Pod
`ContainerCreating` for 10+ minutes, Application `OutOfSync/Missing/Running`, no
error anywhere. Fixed by deploying etcd separately with
`preUpgradeJob.enabled=false` — which also replaced an **unpinned
`bitnamilegacy/etcd:latest`** with a pinned tag.

**Churn.** `platform-etcd` sits `OutOfSync` on exactly one genuine field: a
`checksum/token-secret` annotation over a **randomly generated** JWT key, so
every render differs. That is a *documented* legitimate cause ("Helm charts that
use non-deterministic functions"). But `ignoreDifferences` alone made it worse —
Argo CD stopped reporting the diff and kept writing it, rolling a **quorum
system** on every sync. StatefulSet generation climbed while the Secret's
`resourceVersion` never moved. `RespectIgnoreDifferences=true` stopped it.

> **Suppressing a report without stopping the write is worse than doing nothing,
> because it hides the churn.**

Full detail and the measurements: `gitops/platform/README.md` and `VERIFIED.md`.

## 4f. Versions

`versions.env` is the single source of truth; every install script sources it.
The same component used to be pinned in three places and had already drifted.

```bash
./scripts/check-versions.sh      # diffs every pin against upstream, non-zero if behind
```

Pinning is right — a floating tag means the cluster changes with no commit — but
a pin nobody re-checks is an unpatched version with extra steps, so staleness is
made cheap to see. The checker counts "could not check" separately from
"current": GitHub rate-limits at 60/hour, and a checker that reports success
when it failed to check is worse than none.

**The worst offender was not in any list**: APISIX's bundled etcd ran
`bitnamilegacy/etcd:latest` — unpinned, from Bitnami's *archived* catalogue.
Worth knowing that `docker.io/bitnami/etcd` now has **no tags at all** since
Bitnami went subscription-only, so the archived repo is the only pullable one.

## 5. What the playground does NOT allow

Verified by running it, not by reading docs:

| | |
|---|---|
| `eks:CreateNodegroup` | **DENIED** on every account tested. Use `create_self_managed_nodes = true` |
| `eks:CreateFargateProfile` | **DENIED by an organization SCP**, above account IAM. An IAM allow cannot override an SCP deny |
| `eks:AssociateAccessPolicy` | **DENIED** — this is what breaks the community EKS module |
| `iam:CreateRole` | only for `eksClusterRole`, `eksWorkerNodeRole`, `AmazonEKSFargatePodExecutionRole` — **exact names** |
| `iam:ListAttachedUserPolicies` | **DENIED** — you cannot enumerate your own permissions |
| `us-east-1e` | no `t3.medium`, and EKS will not put a control plane there |
| every instance type except `t3.medium` | **DENIED by an organization SCP.** t3.large, t3.xlarge and m5.large all refused. "Use a bigger node" is not an available answer |
| `servicequotas:GetServiceQuota` | **DENIED by an SCP** — you cannot read your own quotas either |
| `eks:UpdateClusterConfig` | **DENIED.** The API endpoint's `public_access_cidrs` is therefore **immutable after CreateCluster** — see below |
| `eks:DeleteAccessEntry` | **DENIED**, so `terraform destroy` cannot tear the cluster down — see below |

**Self-managed nodes are the way through, and they work.** A managed node group
is not privileged magic — it is AWS running launch template + autoscaling group
+ access entry for you, and all three of those APIs *are* granted. Verified: two
EC2 nodes Ready on EKS v1.33.

**Do not reach for `terraform-aws-modules/eks` on this account.** It is the right
choice generally and cannot work here: it hardcodes
`bootstrap_cluster_creator_admin_permissions = false` (main.tf line 57, not a
variable) and grants the creator admin via `eks:AssociateAccessPolicy`, which is
denied — producing a cluster with healthy running nodes and **no principal able
to administer it**. `terraform/eks` sets that flag true, so EKS grants admin
server-side during `CreateCluster` with no extra call. Both root modules are
kept: the module for real work, the explicit one for when you need to see which
call was refused.

**Check ALL attached policies before concluding something is denied.** There are
eight; reading one led to a wrong conclusion about EKS entirely.

EC2, S3, RDS, VPC are all permitted but granted by a policy you cannot read.
Probe with `--dry-run` instead of guessing:

```bash
aws ec2 run-instances --dry-run --image-id ami-... --instance-type t3.medium --count 1
# DryRunOperation: Request would have succeeded, but DryRun flag is set
```

---

## 6. Traps that cost hours — do not rediscover these

**Your public IP rotating costs a full cluster rebuild here.** The EKS API
endpoint is locked to `public_access_cidrs`. If your address has changed since
`terraform.tfvars` was written, everything still builds — the cluster reaches
`ACTIVE` and Terraform reports success — and then every `kubectl` call hangs,
because the API will not talk to you.

It surfaces in `eks-up.sh` phase 2 as *"waiting for the vpc-cni daemonset to
appear"* that never returns. It reads like a slow CNI and it is a firewall.

And it cannot be corrected in place:

```
Error: updating EKS Cluster VPC configuration: AccessDeniedException:
User is not authorized to perform this action
```

`eks:UpdateClusterConfig` is denied, so the address you build with is the
address you are stuck with. On a normal AWS account this is a one-line fix; here
it is a destroy and recreate, roughly 20 minutes. `eks-up.sh` now preflights the
tfvars IP against your actual one and refuses in about five seconds instead.
Cost when it was learned: 11 minutes of hanging, then the rebuild anyway.

**And `terraform destroy` cannot do that rebuild for you**, because
`eks:DeleteAccessEntry` is denied too:

```
Error: deleting EKS Access Entry (...): AccessDeniedException:
not authorized to perform: eks:DeleteAccessEntry
```

Terraform destroys dependents before their parent, so it tries the access entry
first and stops there. `eks:DeleteCluster` **is** granted, and deleting a cluster
removes its access entries implicitly — so the way through is out-of-band:

```bash
aws eks delete-cluster --name andrei-lab-eks
# wait for it to disappear, then drop the orphaned state entry
terraform -chdir=terraform/eks state rm 'aws_eks_access_entry.node[0]'
./scripts/eks-up.sh
```

Worth noticing what this pair of denials means in combination: on this account a
cluster is **immutable and not cleanly destroyable through IaC**. Terraform can
build it and can neither reconfigure nor remove it. That is a fair thing to have
an opinion about in an interview — it is the difference between "I ran
terraform" and "I know what my IaC does not control".

**`curl ifconfig.me` returns IPv6.** A security group rule wants IPv4. Use
`curl -4`, or `python3 -c "import urllib.request;print(urllib.request.urlopen('https://checkip.amazonaws.com').read().decode())"`.

**A host cannot reach its own public IP.** `wait_for` and `uri` run *on the
target*. Pointing them at `ansible_host` sends the packet out to the internet
gateway and back into a security group that only admits your laptop's `/32`. It
times out with `http_code=000`. Use `127.0.0.1` or `private_ip`. This bit three
separate times — MinIO, cluster-config, and the OIDC tasks. See drills/14.

**Keycloak's `iss` must stay the public URL** even though Ansible reaches it over
loopback. That is what `KC_HOSTNAME` pins, and why Kong's credential lookup
works. Do not "fix" it to loopback.

**`group_vars/vault.yml` is silently ignored.** It declares variables for a group
named `vault`. Use `group_vars/all/vault.yml`. See drills/16 — this is the worst
bug in the repo's history because it fails *open*.

**Check the exit code you think you are checking.**
```bash
ansible-playbook ... > run.log 2>&1
echo "ANSIBLE_EXIT=$?" >> run.log    # NOT `echo $?` after a later command
```

**`kubectl apply -f` applies documents in file order.** A `KongConsumer` before
its credential `Secret` is rejected by the admission webhook — and succeeds on a
re-run, which hides it.

**Scaling a webhook's Deployment to 0 does not disable it.** The
`ValidatingWebhookConfiguration` is cluster-scoped, outlives the pods, and with
`failurePolicy: Fail` breaks *unrelated* workloads. `helm uninstall`, don't
`scale`.

**Probes kill slow starters on a throttled box.** Kong's ingress-controller and
Rancher both CrashLoopBackOff'd because their probe budgets assumed a healthy
CPU. The role already widens Kong's; Rancher may still need
`failureThreshold: 90` patched onto its `startupProbe`. See drills/15 and 17.

**Generated YAML: use `yamlencode`, never an indented heredoc.** Terraform's
`<<-` strips the smallest common indent across all lines, and `%{if}` marker
lines participate in that calculation while emitting nothing. Moving a directive
silently reindents everything after it. Cost here: three EC2 nodes that ran for
20 minutes without joining, with no error anywhere.

**`kubectl set image` does not work on a CRD.** It resolves the type against
kubectl's compiled-in scheme rather than API discovery:

```
no kind "Rollout" is registered for version "argoproj.io/v1alpha1"
```

Use `kubectl patch`, which goes straight to the API server. The same applies to
`kubectl set env`, `kubectl scale` on custom kinds, and friends.

**Setting `args` without `command` replaces the image's CMD.** The podinfo image
has no ENTRYPOINT, so adding `args: ["--random-delay"]` made the container try to
exec `--random-delay` as a binary. Set both.

**Check the image tag exists before concluding a controller judged anything.**
`podinfo:6.7.2` and `6.7.3` do not exist — the releases jump from 6.7.x to 6.9.x.
Flagger reported "canary deployment not ready" and then "Canary failed! Scaling
down", which is indistinguishable from a metric-driven rollback at a glance.

**A scenario must print what it READ, not what it expected.** The first version
of scenario 06 printed "aborted and rolled back" while its `kubectl set image`
had silently failed. Same class of bug as scenario 02. Assert, then report.

**Diagnose memory vs CPU before acting:**
```bash
free -m                  # available -> memory
top -bn1 | grep '%Cpu'   # st -> hypervisor steal, unfixable from inside
```

---

## 7. Ansible version notes

Built against **ansible 14 / ansible-core 2.21**. Two removals that break older
copies of this repo:

- `stdout_callback = yaml` — **removed** in community.general 12. Use
  `stdout_callback = default` + `result_format = yaml` (already fixed in
  `ansible.cfg`).
- the `db:` parameter — **removed** in community.postgresql 4. It is `login_db:`
  now, except `postgresql_db` which wants `maintenance_db:`. Check with
  `ansible-doc -j community.postgresql.<module> | jq '.[].doc.options | keys'`.

---

## 8. Verifying a build

```bash
export ES=http://<es-01>:9200
./scripts/es health          # expect status=green, 3 nodes, 0 unassigned
./scripts/seed-logs.sh 5000

# Kong: open route, JWT route, and a tampered token
curl -s -o /dev/null -w '%{http_code}\n' http://<k3s>:30080/demo       # 200
curl -s -o /dev/null -w '%{http_code}\n' http://<k3s>:30080/secure     # 401
TOKEN=$(curl -s -X POST http://<k3s>:30081/realms/lab/protocol/openid-connect/token \
  -d grant_type=password -d client_id=lab-api -d username=labuser -d password=labpassword \
  | jq -r .access_token)
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" http://<k3s>:30080/secure  # 200
```

Service URLs (all firewalled to `my_ip_cidr` — if your IP rotates, everything
dies at once and you must update `terraform.tfvars` and re-apply):

| service | where |
|---|---|
| Elasticsearch | `http://<es-01>:9200` |
| Kibana | `http://<es-01>:5601` |
| MinIO console | `http://<es-01>:9001` |
| Kong | `http://<k3s>:30080/demo` and `/secure` |
| Keycloak | `http://<k3s>:30081` |
| Rancher | `https://<rke2>:30443` (self-signed) |
| RDS | private only — reach it *through* es-01 |

---

## 9. Working style expected here

- **Verify, do not assert.** Every claim in `drills/` has real command output
  behind it. If you add one, run it first.
- **Report failures honestly.** The drills are valuable *because* they document
  what broke. Do not quietly fix and move on — write down the error text.
- **Never commit secrets.** `.gitignore` covers `inventory/hosts.ini`,
  `inventory/group_vars/all/vault.yml`, `terraform.tfvars`, `*.tfstate*`.
- **Destroy when done**, or let the playground expire:
  `terraform -chdir=terraform/eks destroy && terraform -chdir=terraform/aws destroy`
