# What I built on AWS, and what it taught me

The GCP counterpart is `~/gcp/STORY.md`. This one is deliberately shaped the
same way, because the comparison is the point.

## The one-sentence version

> I built a reproducible EKS platform on AWS — Terraform for infrastructure,
> **both** Argo CD and Flux for workloads — and then broke it on purpose twelve
> different ways to find out where the two controllers actually differ.

The second clause is what makes this different from a tutorial. Anyone can get
Argo CD to deploy an app. The interesting question is what each tool does when
something is wrong, and that only has an answer if you go and break it.

## What exists

**Terraform** — `terraform/bootstrap` (state bucket, local state, solves the
backend chicken-and-egg), `terraform/aws` (Elasticsearch/Kibana/MinIO/Postgres/
RDS, k3s + Kong + Keycloak, RKE2 + Rancher), `terraform/eks` (EKS with
self-managed nodes), `terraform/eks-module` (the same cluster via the community
module, kept deliberately as a comparison — see below).

**GitOps** — one repository reconciled by Argo CD and Flux **simultaneously**,
into two namespaces, from the same kustomize base. Anything that differs between
them is a property of the controller, not of the manifests.

**Progressive delivery** — Argo Rollouts and Flagger, both working, both
measured, plus header/cookie A/B on ingress-nginx.

**`gitops/scenarios/01`–`12`** — the actual deliverable. Each is three bash
functions, runs the same break against both controllers, and prints timestamped
observations rather than conclusions.

## The talking points that carry weight

### 1. An IAM allow is not an effective permission

`eks:CreateFargateProfile` is granted by the account's IAM policy and **denied by
an organization SCP** — a boundary above the account that no IAM allow can
override. Same for every EC2 instance type other than `t3.medium`, and for
`servicequotas:GetServiceQuota`, so you cannot even read your own limits.

The practical lesson: check **all** attached policies, then check for SCPs, then
probe with `--dry-run` rather than reasoning about it. Reading one of eight
policies led me to conclude EKS was unusable here. It was not.

### 2. A managed node group is not privileged magic

`eks:CreateNodegroup` is denied on this account. But a managed node group is AWS
running three APIs on your behalf — launch template, autoscaling group, access
entry — and **all three are granted**. Self-managed nodes work where the managed
API is refused.

The corollary is the more useful half: **`terraform-aws-modules/eks` cannot work
here**, and not for a reason you would guess. It hardcodes
`bootstrap_cluster_creator_admin_permissions = false` and grants the creator
admin through `eks:AssociateAccessPolicy`, which is denied — producing a cluster
with healthy running nodes and **no principal able to administer it**. The
explicit module sets that flag true so EKS grants admin server-side during
`CreateCluster`, with no second API call.

Both are kept in the repo: the module for real work, the explicit one for when
you need to see which call was refused.

### 3. EKS caps pods by ENI, not CPU — and the fix has two halves

```
0/2 nodes are available: 2 Too many pods
cpu 680m (35%)          <- plenty free
max_pods/node: 17
```

Every EKS pod takes a real VPC IP from an elastic network interface, so a
`t3.medium` allows **17 pods** however idle it is. Argo CD (7) + Flux (5) +
Rollouts + ingress-nginx + Flagger + Prometheus does not fit in three of those.
**This is invisible on GKE and on k3s**, which use overlay networks.

`ENABLE_PREFIX_DELEGATION=true` on the `aws-node` daemonset is the well-known
half. The half that is not: **kubelet computes `max-pods` once, at bootstrap**,
from the instance type. Flip only the daemonset and existing nodes keep
advertising 17 forever. You need the CNI setting *and* `--max-pods` pinned in the
nodeadm config, *and* the daemonset patched before any node joins — which is why
the build is three phases, not one `terraform apply`.

Result: **110 allocatable pods per node, 58 pods running, 0 Pending.**

### 4. Argo CD and Flux disagree about what "ready" means

This is the sharpest thing in the repo, and it took two scenarios to see it.

Delete a namespace out from under both controllers, leaving git untouched:

```
argocd  t+12s  OutOfSync/Missing   pods=0
        t+24s  Synced/Progressing  pods=3    <- recovered, and said so
flux    t+12s  ready=True          pods=0
        t+120s ready=True          pods=0    <- gone, and still says ready
```

Flux is not broken. `Ready` on a Kustomization means **"my last apply
succeeded"**. Argo CD's `Synced/Healthy` means **"the cluster matches git and
the workloads are up"**. Those are different claims, and only one of them is
what you want on a dashboard at 3am.

And then it inverts: on `git push` → live, **Flux is 78s and Argo CD is 155s**,
because Argo CD polls every 180s by default. Neither tool is better. They are
optimised for different questions.

### 5. The same question, a different subsystem, the opposite answer

Manual drift on a plain Deployment: **Argo CD 10s, Flux still drifted at 80s**.

Manual drift on a **Helm-managed** Deployment: Argo CD 10s again — and Flux
**never corrects it**, while reporting `Ready=True reason=InstallSucceeded`.
`spec.driftDetection.mode` defaults to `disabled` in helm-controller, and even
switched on it runs on the reconcile interval rather than a watch.

So "Flux corrects drift" is not a property of Flux. It is a property of
kustomize-controller, and helm-controller makes a different choice. Generalising
from one subsystem to a whole tool is how you get surprised in production.

### 6. Neither GitOps controller does progressive delivery, and the two that do disagree about what a step is

Argo CD and Flux both stop at "apply the manifests". A broken release is applied
faithfully and stays broken; recovery is a human `git revert`.

- **Argo Rollouts** — steps are a *script*: `setWeight 25`, `pause 30s`. The
  controller advances on a timer and only stops if an `AnalysisTemplate` you
  attached says stop. Analysis is optional, and by default nothing judges.
- **Flagger** — steps are a *consequence*: `stepWeight 10` means "move 10% **if
  the metrics pass**". Analysis is not decoration, it is the loop.

Measured: Flagger rolled back a bad release in **90s with no analysis
configuration written anywhere**. Argo Rollouts needed an explicit
`AnalysisTemplate` **and** `progressDeadlineAbort: true` to reach 50s.

### 7. Two safety nets that each cannot see the other's failure

Worth being able to name which one caught a given incident.

| failure | caught by | why the other is blind |
|---|---|---|
| broken image, never becomes ready | `progressDeadlineAbort` in **100s** | Rollouts only re-points the canary Service once the canary ReplicaSet has an available pod. It never does, so **both** Services keep the stable hash and the analysis correctly measures healthy old pods and passes |
| healthy but too slow | the AnalysisTemplate in **50s** | the rollout *is* progressing — toward something bad. No deadline is exceeded |

The first row is the one people get wrong, including me: I assumed adding a
traffic provider would let analysis catch a broken image. It does not, and the
`AnalysisRun: Successful` is not a bug.

### 8. Debugging the observability of the thing that observes

Flagger stalled with:

```
Halt advancement no values found for nginx metric request-success-rate
probably podinfo.demo-flagger is not receiving traffic
```

— while the app was visibly serving requests. Two independent causes produce
that identical message: **ingress-nginx ships with metrics disabled**, so the
series never exists; and the load generator was pointed at the Service, so its
traffic bypassed nginx and was never counted. Real traffic the metric cannot see
looks exactly like no traffic.

Then a third: `request-success-rate` is a *rate over the last minute of
namespace-wide counters*, so error traffic left running from a previous
experiment made the **next** good release fail at "success rate 36.89% < 99%"
while every manual curl returned 200. Experiment hygiene is part of the test.

### 9. Boundaries fail closed, and quietly

- An Argo CD `AppProject` rejected a Helm chart source **at the spec level** —
  no failed sync, no `operationState`, `Unknown/Unknown` in `kubectl get app`,
  reason only in `status.conditions`.
- `clusterResourceWhitelist: []` silently forbids `CreateNamespace=true`,
  because a Namespace is cluster-scoped.
- A `SealedSecret` copied into another namespace is **refused** — the namespace
  is inside the encrypted envelope, not a label on it.

The first two look like the tool being slow. The third is the feature working.

### 10. Reachable is not the same as delivered

The Argo CD webhook works on a locked-down playground — NodePort plus a security
group scoped to GitHub's published hook ranges. But argocd-server answers plain
HTTP with a **307**, and **GitHub does not follow redirects for webhook
delivery**. The hook records a response, shows as delivered, and Argo CD never
hears about it. Nothing anywhere reports an error.

HTTPS NodePort, `insecure_ssl=1`, HMAC doing the real work: HTTP 200 and both
Applications refreshed immediately, against ~155s of polling. And the poll stays
on, because webhook delivery is best-effort — push for speed, poll for
correctness.

## Mistakes worth admitting

**A `%{if}` inside a `<<-` heredoc silently reindented generated YAML.**
Terraform's `<<-` strips the smallest common indent across all lines, and the
directive line participates in that calculation while emitting nothing. Three
EC2 instances ran for 20 minutes and never joined the cluster. EC2 said the
launch succeeded; the ASG said Healthy; there were simply no nodes. Now built
with `yamlencode`, which cannot emit misindented YAML.

**I diagnosed the apt hang twice before measuring it.** dpkg lock, then a
cloud-init race. It was neither: `install_recommends` was pulling 88 packages
where 2 were needed.

**`group_vars/vault.yml` is silently ignored** — it declares variables for a
group named `vault`. Every secret fell back to `CHANGE-ME-IN-VAULT`. It fails
*open*, which makes it the worst bug in the repo's history.

**A scenario that prints its conclusion unconditionally is not a measurement.**
Scenario 02 hid a rejected patch and reported "Healthy" for 96s. Scenario 06's
first version announced "aborted and rolled back" while its `kubectl set image`
had failed — `set` resolves types against kubectl's compiled-in scheme and
cannot touch a CRD at all.

## AWS vs GCP, phrased for an interviewer

| AWS | GCP |
|---|---|
| VPC (regional) | VPC (**global**) |
| Subnet (one AZ) | Subnet (**one region**, all zones) |
| Security Group | firewall rule targeted by **network tag / service account** |
| NAT Gateway (per AZ, an instance) | Cloud NAT (regional, SDN, nothing to size) |
| IRSA | Workload Identity |
| S3 + `use_lockfile` (conditional writes) | GCS backend, locking built in |
| EKS + managed node groups | GKE Standard |
| EKS on Fargate | GKE Autopilot |
| **pods per node capped by ENI** | **overlay network — no such cap** |
| SCPs (org-level deny, above IAM) | org policy constraints |

Two of those rows are the ones I would actually lead with, because both cost me
real time and both are structural rather than trivia:

**Pod density.** AWS gives every pod a routable VPC IP, which is excellent for
network policy and observability and terrible for density on small instances.
GCP's overlay does the opposite. The same manifest set fits on 3 GKE
`e2-medium`s and does not fit on 3 EKS `t3.medium`s.

**Where the denial happens.** On GCP an org policy denied a node disk size, and
the *cluster create call succeeded* — the failure surfaced later, when the
managed instance group tried to create VMs, and GKE read that as transient and
auto-repaired forever. On AWS an SCP denies the API call itself, immediately and
with a policy ID in the error. AWS's version is far easier to debug; GCP's is
far easier to trip over.

## What I would do differently in production

- **Pin the chart, not a range.** A semver range in a `HelmRelease` means the
  cluster can change with no commit — which quietly ends "the repo is the source
  of truth".
- **Turn on `driftDetection` and know it is a poll.** Or accept that Helm-managed
  objects are not self-healing and say so out loud.
- **Both safety nets on every Rollout**, since they cover disjoint failures.
- **A real Ingress with a real certificate** for webhooks, not a NodePort with
  `insecure_ssl=1`.
- **Back up the sealed-secrets sealing key**, or every `SealedSecret` in git is
  dead the next time the cluster is rebuilt.
- **Separate kubeconfig per environment.** A production EKS context sitting next
  to a lab context in one file is an outage waiting to happen — which is why
  every script here writes `~/.kube/andrei-lab-eks` and never touches
  `~/.kube/config`.
