# Platform Lab — Elasticsearch, Ansible, Rancher, Kong

A self-contained lab that builds a 3-node Elasticsearch cluster, Kibana, MinIO
(for snapshots), PostgreSQL, and a k3s cluster running Rancher and Kong —
entirely with Ansible.

The point is not the end state. The point is that **building it with Ansible
teaches Ansible**, and **breaking the Elasticsearch cluster on purpose teaches
Elasticsearch**. Both are gaps on the target job description; after this repo,
neither is.

---

## Versions

Every pin lives in `versions.env`; nothing is pinned inline. Check for drift:

```bash
./scripts/check-versions.sh     # non-zero if anything is behind upstream
```

Pinning is deliberate — a floating tag means the cluster can change with no
commit — so the trade is made visible rather than avoided. The one component
that had gone stale unnoticed was a chart's *bundled* dependency running an
unpinned `:latest` from an archived registry; see `AGENTS.md` §4f.

## The story, for an interview

- **`STORY-AWS.md`** — what this taught me, and the ten findings worth saying
  out loud. Its GCP counterpart is `~/gcp/STORY.md`; the two are shaped the same
  way on purpose, and the AWS-vs-GCP table at the end is the comparison.

## Shareable write-ups

Two published artifacts, both built from measurements in this repo:

- **Architecture** — what builds what, what calls what, and the ordering rules
  that cannot be swapped
  <https://claude.ai/code/artifact/33a25fb7-fda8-46b5-a4ce-b1cb09a33130>
- **GitOps delivery styles** — Argo CD vs Flux, and what canary / blue-green
  actually require
  <https://claude.ai/code/artifact/3bbe06ac-2659-4c85-8f3d-b80bc518dda4>

They are private until shared from the page's share menu.

## Start here

```bash
make help          # everything you can do
make whoami        # which AWS account / cluster am I pointed at?
```

`make` fronts the scripts as a single entry point. (It is Make as a *task
runner*, not a build system -- nothing produces files. `just` or Taskfile are
more honest about that; Make is here because every machine has it.)

Two independent tracks live in this repo:

| Track | What it is | Entry point |
|---|---|---|
| **Elasticsearch lab** | 3-node ES, Kibana, MinIO, PostgreSQL, k3s/RKE2, Kong, Keycloak, Rancher on EC2 | `make ec2` then the playbooks |
| **GitOps lab** | Argo CD and Flux reconciling this repo into one EKS cluster, side by side, plus Argo Rollouts / Flagger / sealed-secrets / Helm | `make eks && make gitops && make addons` |
| **Platform under GitOps** | ingress-nginx, Prometheus/Grafana, APISIX and etcd as Argo CD Applications rather than shell scripts — an app-of-apps with sync waves | `kubectl apply -f gitops/platform/root.yaml` |
| **API gateway** | Apache APISIX alongside Kong, with the control-plane vs data-plane and canary-observability scenarios | `make apisix` |

`make eks` runs a **three-phase** build. Do not replace it with `terraform
apply`: EKS caps pods per node by ENI rather than CPU (17 on a `t3.medium`), and
the fix has to be applied to the CNI daemonset *before any node joins* — kubelet
reads `max-pods` once, at bootstrap. See `AGENTS.md` §4c. Result: **110
allocatable pods per node, 58 running, 0 Pending.**

## GitOps: Argo CD vs Flux, measured

`gitops/` holds a production-shaped pipeline for **both** controllers, deploying
one kustomize base into two namespaces so that any difference you observe is a
property of the controller rather than the manifests.

`gitops/scenarios/` is a harness that applies the **same break to both** and
prints timestamped observations:

```bash
make scenarios            # list them
make scenario ID=03       # run one
./scripts/scenario status
```

Measured on EKS v1.33 with three self-managed nodes:

| | Question | Result |
|---|---|---|
| 01 | namespace deleted out from under it | argocd recovered in 24s · **flux still gone at 120s, reporting `ready=True`** |
| 02 | pod cannot schedule | argocd never broke (selfHeal) · **flux `pending=1` for 84s, reporting `ReconciliationSucceeded`** |
| 03 | manual drift | **argocd ~10s** · flux still drifted at 80s |
| 04 | `git push` to live | **flux 78s** · argocd 155s |
| 05 | a broken release | **neither rolls back** — recovery is a human `git revert` |
| 06 | Argo Rollouts with real traffic routing | rolls back **two ways**: `progressDeadlineAbort` at 100s (broken image) · analysis at 50s (healthy but slow). Neither catches the other's failure |
| 07 | Flagger canary, end to end | good release **Succeeded in 150s** · bad release **Failed and rolled back at 90s**, on metrics alone |
| 08 | header/cookie A/B | **20/0 in both directions at weight 0** — and *not* via Argo Rollouts, which does not support `setHeaderRoute` on nginx |
| 09 | a secret in a public repo | unseals in its own namespace, **refused in another** |
| 10 | "both do Helm" | Helm release Secrets: **Flux 1, Argo CD 0** · drift: argocd 10s, **flux never** (off by default) |
| 11 | how much of git-to-live is the poll | nearly all of it — webhook verified at **HTTP 200, instant refresh** |
| 12 | Flux installing itself declaratively | flux-operator adopted a live `flux install` in **12s** · **web UI on :9080** |

Scenarios 06–12 need `make addons`. Some run against one controller only and say
so — progressive delivery is a *different controller* on each side (Argo Rollouts
vs Flagger), so "both" would not compare like with like.

### The two findings worth leading with

**Argo CD and Flux disagree about what "ready" means.** Flux's `Ready` is *"my
last apply succeeded"*; Argo CD's `Synced/Healthy` is *"the cluster matches git
and the workloads are up"*. That is scenarios 01 and 02 — and then 04 inverts it,
because Argo CD polls every 180s.

**Do not generalise from one subsystem to a whole tool.** Scenario 03 says Flux
corrects drift slowly; scenario 10 says a Flux `HelmRelease` does not correct it
*at all* by default, while reporting `Ready=True`. Same tool, different
controller inside it, opposite answer.

Progressive delivery (`gitops/progressive/`) is a **separate controller** in both
ecosystems — Argo Rollouts or Flagger. Measured: a Rollouts canary promoted
25→50→75→100% cleanly, and on a broken image **capped the blast radius at 25%
but did not roll back** — steps pause, they do not judge.

03 and 04 invert each other, and 01/02 expose the deeper split: **Argo CD's
status answers "does the cluster match git and is it healthy"; Flux's answers
"did my last apply succeed".** Full write-up in `gitops/scenarios/README.md`.

## Hosting

Provisioned by Terraform — see **`terraform/README.md`** for the full comparison
of KodeKloud playground vs your own AWS account vs Hetzner, and which to use for
what. Short version: Hetzner or your own AWS for the persistent lab, KodeKloud
for rehearsing the build under a clock.

```bash
# 1. state bucket + backend init, in one step (see drills/10)
./scripts/tf-init.sh

# 2. the lab itself
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars && $EDITOR terraform.tfvars
terraform apply                       # writes inventory/hosts.ini for you
```

State lives in **S3** — versioned, encrypted, and locked with `use_lockfile`
(S3 conditional writes, no DynamoDB table). `terraform/bootstrap` creates that
bucket and is the one module with local state, because it cannot hold its own.

`scripts/tf-init.sh` prints the AWS account it is about to build in and refuses
to continue unless you confirm it. Set `LAB_ACCOUNT_IDS` to skip the prompt.

The playbooks only need SSH and Ubuntu 22.04/24.04, so any of these work:

| Option | Spec | Cost | Notes |
|---|---|---|---|
| **Hetzner Cloud (recommended)** | 3× CX22 (2 vCPU / 4 GB) + 1× CX32 (4 vCPU / 8 GB) | ~€21/mo | Closest to real ops. Put them on a private network, snapshot the servers when you are done and destroy them — you pay cents to keep snapshots and can restore any time. |
| **One bigger Hetzner box** | 1× CPX41 (8 vCPU / 16 GB) | ~€25/mo | Run the four nodes as LXD or Multipass VMs inside it. Cheaper if you also want other labs. |
| **Local, free** | Laptop with 16 GB+ RAM | €0 | `multipass launch --name es-01 --memory 4G --disk 20G 24.04` ×4. Set `private_iface: ens4`. |

If you go Hetzner, create the private network first and note that the private
interface is usually `enp7s0` — check with `ip -br a` and set `private_iface`
in `inventory/group_vars/all.yml` accordingly.

**Elasticsearch needs 4 GB per node to be pleasant.** 2 GB works but you will
spend time fighting the JVM instead of learning the cluster, which defeats the
purpose.

---

## Run it

```bash
# 0. one-time
pip install ansible                      # the full package, includes collections
cp inventory/hosts.ini.example inventory/hosts.ini
$EDITOR inventory/hosts.ini              # your IPs
$EDITOR inventory/group_vars/all.yml     # private_iface

# 1. secrets -- do NOT leave passwords in vars.yml
#
# NOTE THE PATH: group_vars/all/vault.yml, inside the all/ DIRECTORY.
# group_vars/vault.yml would describe a group named "vault", which has no
# hosts, so it is silently ignored and every secret falls back to its
# "CHANGE-ME-IN-VAULT" default. No error, no warning. See drills/14.
ansible-vault create inventory/group_vars/all/vault.yml
#   minio_root_password: "..."
#   postgres_app_password: "..."
#   rancher_bootstrap_password: "..."
#   keycloak_admin_password: "..."

# verify they actually load -- never assume
ansible all -m debug -a "msg={{ minio_root_password }}" --ask-vault-pass

# 2. check connectivity
ansible all -m ping

# 3. build
ansible-playbook playbooks/site.yml --ask-vault-pass

# or in pieces
ansible-playbook playbooks/elastic.yml --ask-vault-pass
ansible-playbook playbooks/k8s.yml --ask-vault-pass

# 4. RDS -- separate, because the master password comes out of Terraform state
#    rather than out of vault. It is generated, never typed, never committed.
ansible-playbook playbooks/rds.yml --ask-vault-pass \
  -e rds_master_password="$(terraform -chdir=terraform/aws output -raw rds_password)"
```

`playbooks/rds.yml` targets **es-01**, not the database: RDS has no sshd and is
not publicly reachable, so it is configured *through* a host that is allowed to
talk to it. That is the general shape of managing any managed service.

Then:

```bash
export ES=http://<es-01-ip>:9200
./scripts/es health
./scripts/seed-logs.sh 5000
./scripts/es indices
```

- Kibana → `http://<es-01-ip>:5601`
- MinIO console → `http://<es-01-ip>:9001`
- Rancher → `https://rancher.<k3s-ip>.sslip.io`
- Kong proxy → `http://<k3s-ip>:30080/demo` (open)
- Kong secured → `http://<k3s-ip>:30080/secure` (JWT required — drill 09)
- Keycloak → `http://<k3s-ip>:30081` (admin)
- RDS → `terraform -chdir=terraform/aws output rds_endpoint`

Switch distribution with one variable — `k8s_distribution: k3s` or `rke2` in
`inventory/group_vars/all.yml`. Both install on a plain Ubuntu box with no AWS
service dependency, so both work on a KodeKloud playground instance.

---

## What each piece is teaching you

| Directory | JD requirement it closes |
|---|---|
| `roles/elasticsearch/` | Elasticsearch cluster deployment and administration |
| the whole repo | Configuration management (Ansible) |
| `roles/kubernetes/` | Rancher, Helm, container stacks (k3s **or** RKE2) |
| `kubernetes/kong/` + `roles/kubernetes/tasks/oidc.yml` | Kong API Gateway, rate limiting, JWT/OIDC auth *(nice-to-have)* |
| `roles/postgresql/` + `playbooks/rds.yml` | Relational databases, self-managed **and** managed *(nice-to-have)* |
| `roles/storage/` | EBS volumes, filesystems, mounting things that stay mounted |
| `terraform/bootstrap/` | Remote state, locking, and why both are set up that way |
| `terraform/eks/` | EKS with **self-managed nodes** -- the only path that works where `eks:CreateNodegroup` is denied |
| `terraform/eks-module/` | The same cluster via `terraform-aws-modules/eks`, and why it cannot be used on a locked-down account |
| `gitops/` | Argo CD **and** Flux, production-shaped, side by side |
| `gitops/scenarios/` | Reproducible experiments: what each controller does when things break |
| `scripts/` | Shell scripting |
| `drills/` | The answers you give when they probe any of the above |

## What Terraform builds

| Resource | Why it is there |
|---|---|
| 3× EC2 + 1× EC2 | the Elasticsearch nodes and the k3s/RKE2 node |
| security group, key pair | SSH and service access, scoped to your own IP |
| **EBS data volume per ES node** | data outliving the instance, and a disk small enough to fill on purpose — drill 12 |
| **S3 bucket** | Terraform state: versioned, encrypted, locked — drill 10 |
| **RDS PostgreSQL** | the managed counterpart to the one on es-01 — drill 11 |
| EKS cluster + node group | separate module, separate state — `terraform/eks/README.md` |

---

## Ansible concepts to be able to explain

Do not just run the playbooks — you need to be able to talk about them.

- **Idempotency** — run `site.yml` twice. The second run should report almost all
  `ok` and no `changed`. That property is the whole point of configuration
  management, and "what does idempotent mean" is a near-certain interview question.
- **Roles** — reusable units: `tasks/`, `handlers/`, `templates/`, `defaults/`.
- **Handlers** — `notify: restart elasticsearch` fires *once* at the end of the
  play, no matter how many tasks notified it. Compare with a plain restart task.
- **Templates** — `elasticsearch.yml.j2` builds the seed-host list from the
  inventory. Add a fourth node to `hosts.ini`, re-run, and watch every node's
  config update itself. That demo alone sells the idea in an interview.
- **`serial: 1`** — the elastic play deploys one node at a time. That is a rolling
  deployment, and it is why the playbook is safe to re-run against a live cluster.
- **Vault** — secrets encrypted at rest in Git.
- **Variable precedence** — `defaults/` < `group_vars/` < `host_vars/` < `-e`.

---

## Work through the drills in order

`drills/01` … `drills/12`. Each one has a "say this in the interview" section at
the end. Those are the actual deliverable — the cluster is just the thing that
makes them true.

| | |
|---|---|
| 01–05 | Elasticsearch: health, shards, watermarks, snapshots, rolling upgrades |
| 06 | Elasticsearch security |
| 07–08 | Rancher vs RKE2, Kong |
| **09** | **Kong + Keycloak: what OSS JWT auth is and is not** |
| **10** | **Terraform state, S3 locking, the bootstrap chicken-and-egg** |
| **11** | **RDS vs Postgres on EC2** |
| **12** | **EBS: why the device name lies, and mounting by UUID** |
| **13** | **Not every AZ can do every thing (us-east-1e)** |
| **14** | **Four Ansible bugs this lab actually hit** |
| **15** | **Four Kubernetes failures: probes, rollouts, webhooks, ingress** |
| **16** | **The vault file that was never loaded** |
| **17** | **1.9 GB free and still dying: burst credits and steal time** |

Do drill 01, 03 and 05 with the cluster *running* and *break it for real*. A
candidate who has recovered a red cluster sounds completely different from one
who has read about it, and interviewers can tell within two follow-up questions.

---

## Put this on GitHub

Public repo, real commit history spread over the weeks you actually work on it.
Link it from the CV. It converts "self-directed lab" from a claim into evidence,
and it gives the interviewer something concrete to ask about — which is a much
better conversation than a generic skills list.
