# Terraform — index, and where to actually run this

*Index and runbook written 2026-10-17 from the code, the Makefile, `scripts/`
and git history. Everything under "Hosting options" further down is the older
2026-08 reasoning and is partly superseded; where it disagrees, this section wins.*

## Index of Terraform folders

Each folder has its own README. Status: **ACTIVE** = used by a current make
target/script; **OPTIONAL** = works, run on demand; **LEGACY** = superseded or
reference only.

| Path | Status | What it is | Used by | KodeKloud-safe? |
|---|---|---|---|---|
| [`terraform/bootstrap`](bootstrap/README.md) | ACTIVE | S3 state bucket `andrei-lab-tfstate-<account-id>`, local state | `scripts/tf-init.sh` (every `make state`) | yes: one bucket, no compute |
| [`terraform/eks`](eks/README.md) | ACTIVE | EKS control plane + self-managed t3.medium nodes + NodePort rules; THE lab cluster | `make eks` -> `scripts/eks-up.sh`; `make destroy`; gitops/addons scripts; `playground/setup/up-aws.sh` | yes if `node_max_size` stays within the shared 10 vCPU / 20 GiB; credits pinned `standard`. Do not run beside `terraform/aws` at full size |
| [`terraform/aws`](aws/README.md) | OPTIONAL | EC2 lab: Elasticsearch x N, k3s, optional RKE2, EBS, RDS; writes `inventory/hosts.ini` | `make ec2`, `make destroy`, Ansible playbooks/drills | yes at defaults (4 x t3.medium, credits `standard`, 30 GB gp2); 5 instances = the whole budget |
| [`terraform/gcp-artifactory`](gcp-artifactory/README.md) | ACTIVE (on demand) | Artifactory OSS on one GCE VM, local state | `scripts/gcp-urls.sh`, `scripts/app-urls.sh`, docs | yes (GCP): e2-standard-2, 30G, US, own VPC |
| [`terraform/ecs`](ecs/README.md) | LEGACY | Artifactory on ECS Fargate; superseded by `gcp-artifactory`; never served a request | docs only | borderline: sits exactly on the 2048 CPU / 4096 MB cap; an earlier 8192 MB version caused the recorded violation |
| [`terraform/eks-module`](eks-module/README.md) | LEGACY (reference) | EKS via `terraform-aws-modules/eks` v21; documented as unusable on the playground | CI validate | **no**: node group does not pin `cpu_credits = standard`; same cluster/role names as `terraform/eks` |
| [`terraform/hetzner`](hetzner/README.md) | OPTIONAL (dormant) | Same ES+k3s lab on Hetzner Cloud, local state, about EUR 21/month | README, CI validate | n.a. (not a playground) |
| [`playground/semaphore`](../playground/semaphore/README.md) | OPTIONAL | Semaphore project/templates for the interview game, via the `semaphoreui` provider; local state outside the repo | its own README | n.a. (no cloud resources) |

How they relate to the playgrounds: `bootstrap` -> `eks` / `aws` / `ecs` /
`eks-module` are the **KodeKloud AWS** stacks (all keep state in the bootstrap
bucket under different keys). `gcp-artifactory` is the **KodeKloud GCP** stack
(local state). `hetzner` and `semaphore` are independent of both.
Limits: [`docs/kodekloud-limits.md`](../docs/kodekloud-limits.md) (AWS) and
[`docs/kodekloud-gcp-limits.md`](../docs/kodekloud-gcp-limits.md) (GCP); violations
are recorded against the account, so read them before changing any size.

### What `make` and `tf-init.sh` actually do with state

- `scripts/tf-init.sh [stack]` (default `aws`): checks credentials and the
  `LAB_ACCOUNT_IDS` guard, runs **`apply` on `terraform/bootstrap`** (creates
  the bucket if missing), reads its `state_bucket`, then
  `terraform -chdir=terraform/<stack> init -reconfigure -backend-config=bucket=<bucket>`.
  It inits one stack per call.
- `make state` = `tf-init.sh` for each of `STATE_STACKS = aws eks`
  (Makefile). It does **not** touch `bootstrap`'s own local state, `gcp-artifactory`,
  `hetzner` or `playground/semaphore` (those have no S3 backend).
- **The trap**: a new KodeKloud account has a new account ID, so a new bucket name.
  Every stack's `.terraform/` still remembers the old bucket and fails with "S3
  bucket ... does not exist" until `make state` (or `./scripts/tf-init.sh <stack>`)
  re-initialises it. `terraform/bootstrap` keeps its own **local** state of the old
  account's bucket; `tf-init.sh` does not reset that, and a `terraform.tfstate.acct-<id>.bak`
  in that folder shows it has been set aside by hand before. Check it first.
- `make eks` does not call `tf-init.sh`; `eks-up.sh` assumes the folder is already
  initialised against the current bucket.

## Fresh KodeKloud account: the order

From the repo root. Nothing here was run to write this; it is the order the repo
intends (Makefile, `scripts/eks-up.sh`, AGENTS.md, `playground/GUIDE.md`).

1. **Read the limits** again: `docs/kodekloud-limits.md` (and the KodeKloud page,
   which changes). Note the 3-hour IAM window: do all AWS-API work first.
2. **Credentials**: create an access key in the console, put it in
   `~/.config/platform-lab/aws-lab-creds.env` (mode 600, `KEY=value` lines; never
   `~/.aws/credentials`). Terraform and `eks-up.sh` read the **shell environment**, so
   load it: `set -a; . ~/.config/platform-lab/aws-lab-creds.env; set +a; unset AWS_PROFILE`
   (the playground scripts source this file themselves; `tf-init.sh`/`eks-up.sh` do not).
3. **Confirm the account**: `make whoami`, then `export LAB_ACCOUNT_IDS=<that account id>`
   (otherwise `tf-init.sh` asks you to type it, once per stack).
4. **Bootstrap local state**: check `terraform/bootstrap/terraform.tfstate` belongs to
   this account; if it is the previous account's, move it aside first (see the trap).
5. **State bucket + re-init**: `make state`.
6. **EKS tfvars**: `terraform/eks/terraform.tfvars` is gitignored. It needs
   `public_access_cidrs` containing the IP **as AWS sees it** (`eks-up.sh` checks with
   checkip.amazonaws.com and refuses otherwise; the API CIDR cannot be changed after
   create here), `create_iam_roles = true`, `create_node_group = false`,
   `create_self_managed_nodes = true`, `node_desired_size`, `node_max_size <= 5`.
   Do not copy `terraform.tfvars.example`: it is stale.
7. **Cluster**: `make eks` (about 25 min; `./scripts/eks-up.sh`, not plain `terraform apply`).
   Then `make kubeconfig` and check MAXPODS reads 110.
8. **On top of the cluster** (not Terraform): `./scripts/gitops-install.sh`, then
   `./scripts/gitops-addons.sh` (see `NEXT-SESSION.md`); `playground/setup/up-aws.sh`
   for the AWS drills 11-14.
9. **Optional EC2 lab**: `make ec2` (`terraform/aws`). Count instances first:
   EKS nodes + EC2 lab must stay within 10 vCPU / 20 GiB (5 x t3.medium).
10. **GCP, if wanted** (separate playground, separate project ID, local state):
    see `terraform/gcp-artifactory/README.md`.
11. **End of session**: `make destroy` (asks; EKS first, then aws). It ignores errors
    (`-` prefix) and `terraform/eks` cannot be destroyed cleanly (`eks:DeleteAccessEntry`
    denied): use the `aws eks delete-cluster` + `terraform state rm` workaround in
    AGENTS.md section 6. It does not cover `ecs`, `eks-module`, `gcp-artifactory`, `hetzner`.

## Safe to delete?

Nothing was deleted. Candidates, with the evidence:

- **`terraform/ecs`**: nothing in the Makefile, scripts, CI validate or playground
  runs it; superseded by `gcp-artifactory`; never served a request. Keep as the
  documented failure (`docs/ci-track.md`, `VERIFIED.md` cite it) or delete with them.
  Deleting it also means removing `ecs` from `STATE_STACKS` in the Makefile.
- **`terraform/eks-module`**: referenced only by README/STORY-AWS/AGENTS as the
  "why not" and by CI + `STATE_STACKS`. One commit, 2026-08-19. Unsafe to apply
  (unpinned credits). Safe to delete if you drop it from CI (`ci.yml`) and
  `STATE_STACKS`, and edit the README rows that link it.
- **`terraform/hetzner`**: no state, no caller beyond docs and CI validate; keep if the
  "persistent lab" option still matters, otherwise it is dead weight.
- **Keep**: `bootstrap`, `eks`, `aws`, `gcp-artifactory`, `playground/semaphore`.
- Local junk inside folders (not tracked): `terraform/aws/tfplan` and
  `terraform/eks-module/tfplan` are gitignored binary plans from 2026-08-19; they
  contain sensitive values and are stale. Left alone.

---

# Hosting options (older notes, 2026-08)

## Does the JD mention a cloud?

Yes, and it is not GCP:

> *Nice to Have — 2+ years with Public or Hybrid Cloud (**Azure or AWS**)*

Azure or AWS. GCP appears nowhere in the requirements. So **AWS**, and the GCP
playground is not worth Andrei's time for this application.

It is also only a *nice-to-have*, and he partly has it already — IBM Cloud is
hybrid-cloud experience and he holds AWS Cloud Practitioner. Terraform against
real AWS turns "certified" into "has used it", which is the gap worth closing.

---

## The three hosting options

| | KodeKloud AWS playground | Own AWS account | Hetzner |
|---|---|---|---|
| Cost | included in Pro | ~$0.15/hr for all 4 nodes | ~€21/mo |
| Persistence | **none — wiped each session** | full | full |
| Session limit | ~3 hours | none | none |
| Instance sizes | t2/t3 nano–**medium**; hard caps of 2 vCPU and 4 GB RAM per instance, 20 GiB total | anything | anything |
| Disk | gp2, **30 GB max** | anything | anything |
| Regions | us-east-1, us-east-2, us-west-2 | any | any |
| CPU credits | **standard only** — unlimited mode gets your session suspended | your choice | n/a |
| IAM roles | restricted to `iamuser*` patterns | full | n/a |
| Good for | AWS practice, rehearsing the build | the AWS line on the CV | the persistent lab |

`t3.medium` is 2 vCPU / 4 GB — exactly the minimum sane Elasticsearch node, and
3 ES nodes + 1 k3s node is 4 of the playground's 5-instance cap. So the specs
**do** fit. The problem is not size, it is the clock.

## EKS: supported, but not usable as the lab host

EKS is on the allowed list, and you can genuinely provision a cluster and node
group with Terraform. But the per-cluster caps make it useless for *this* stack:

- **Max 3 pods per namespace**
- **Max 512 MiB memory and 256 millicores CPU per pod**
- Cumulative 2000 millicores / 4096 MiB per cluster; 6000m / 12 GiB account-wide
- Node group max 3 nodes, t3.medium ceiling

Rancher alone needs more pods and far more than 512 MiB. Elasticsearch on
Kubernetes is out of the question at that pod size. So:

**Run the lab stack on k3s or RKE2 on an EC2 instance.** That is where Rancher,
Kong and the rest live. Rancher is a management plane — it does not care what is
underneath, which is the whole point of drill 07.

**Treat EKS as a separate 30-minute exercise:** Terraform up a cluster and node
group, `aws eks update-kubeconfig`, deploy one small nginx Deployment, look at
how the managed control plane differs, tear it down.

One gotcha that breaks most Terraform EKS modules here — **corrected against a
live playground on 2026-08-18**, because the version of this note written from
the docs was wrong in two ways:

The boundary policy is called `AWS_EKSECSWithConditions`. It permits
`iam:CreateRole` for a **fixed set of role names**:

```
arn:aws:iam::<acct>:role/eksClusterRole
arn:aws:iam::<acct>:role/eksWorkerNodeRole          <- NOT AmazonEKSNodeRole
arn:aws:iam::<acct>:role/AmazonEKSFargatePodExecutionRole
```

and `iam:AttachRolePolicy` only for `AmazonEKSClusterPolicy`,
`AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`,
`AmazonEC2ContainerRegistryReadOnly` and `AmazonSSMManagedInstanceCore`.

Two corrections to the earlier note:

1. The node role is **`eksWorkerNodeRole`**, not `AmazonEKSNodeRole`.
2. The roles do **not** pre-exist in a fresh playground — they have to be
   created, and creating them is permitted *provided the names match exactly*.
   So `create_iam_roles = true` is the right setting here, with the names left
   at their defaults. A role called `andrei-lab-eks-cluster-role` is refused.

The community `terraform-aws-modules/eks` module still fails, because it names
its own roles. `terraform/eks` uses the raw `aws_eks_cluster` and
`aws_eks_node_group` resources for exactly this reason.

### The policy is time-boxed

Every statement carries a condition like:

```json
"DateGreaterThan": {"aws:CurrentTime": "2026-08-18T09:24:03Z"},
"DateLessThan":    {"aws:CurrentTime": "2026-08-18T12:24:03Z"}
```

Three hours from session start, enforced in IAM rather than by deleting
anything. When the window closes, calls start returning AccessDenied while the
resources are still running — so a failing apply late in a session may mean the
clock ran out, not that anything is wrong with the config. Check with:

```bash
aws iam get-policy-version --policy-arn arn:aws:iam::<acct>:policy/AWS_EKSECSWithConditions \
  --version-id v1 --query 'PolicyVersion.Document' | grep CurrentTime
```

`iam:ListAttachedUserPolicies` is explicitly **denied**, so you cannot enumerate
what else is attached — EC2, S3 and RDS are all permitted but granted by a
policy you cannot read. Probe with `--dry-run` instead:

```bash
aws ec2 run-instances --dry-run --image-id ami-... --instance-type t3.medium --count 1
# DryRunOperation: Request would have succeeded, but DryRun flag is set
```

## Also worth knowing: managed OpenSearch is available

`t3.small.search` / `t3.medium.search`, **1 domain, 1 data node, no dedicated
masters**. One node means no cluster mechanics — no shard reallocation, no
quorum, nothing to break — so it does not replace the self-managed cluster. It is
worth spinning up once via Terraform to see the managed side of the same engine,
and it is a fair thing to mention alongside AWS experience.

## Recommendation: use two of them

**Persistent lab → Hetzner (`terraform/hetzner`) or his own AWS account.**
The drills that matter — break a node, watch a rebalance, fill a disk until
flood stage, do a rolling restart, restore a snapshot — need a cluster that is
still there tomorrow. It also gives him a GitHub commit history spread over
three weeks, which is what makes the CV's project section evidence rather than
a claim.

If he wants AWS specifically on the CV, his own account with `terraform destroy`
discipline is genuinely cheap: 4× t3.medium is about **$0.15/hour**, so 40 hours
of lab work across three weeks is roughly **$6**. Set a billing alarm at $20 and
run `terraform destroy` every time he stops. The risk is forgetting; the mitigation
is that everything rebuilds in 20 minutes from this repo.

**KodeKloud → the rehearsal.** Its 3-hour wipe is a constraint worth embracing:
if `terraform apply && ansible-playbook site.yml` cannot produce a working
cluster inside 20 minutes, the automation is not good enough yet. Rebuilding
from scratch repeatedly is how the whole stack ends up in his fingers rather
than in his notes. And "I can rebuild my entire lab from Terraform and Ansible
in twenty minutes" is a strong thing to be able to say out loud.

## Playground-specific gotchas already handled in the code

- `credit_specification { cpu_credits = "standard" }` on every instance —
  unlimited mode is a **policy violation that suspends the session**.
- Default VPC via data source, no VPC creation (restricted there).
- No IAM roles or instance profiles — snapshots go to MinIO on the box, not S3.
- gp2 / 30 GB defaults.
- `elastic_ilm_poll_interval: 10s` so a rollover is observable inside one
  session instead of on a 10-minute production tick.

For the ILM drill in a short session, set the policy's `min_age` in minutes
rather than days — same mechanics, visible in real time.

---

## Run it

> Superseded for `terraform/aws`: its S3 backend has no bucket in the file, so a
> plain `terraform init` fails. Use `make state` / `./scripts/tf-init.sh aws`
> first (see the runbook at the top). The block below still works for `terraform/hetzner`.

```bash
cd terraform/aws          # or terraform/hetzner
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars  # my_ip_cidr = "$(curl -s ifconfig.me)/32"

terraform init
terraform apply
```

Terraform writes `inventory/hosts.ini` itself — no copy-pasting IPs between
Terraform and Ansible. Then:

```bash
cd ../..
ansible all -m ping
ansible-playbook playbooks/site.yml --ask-vault-pass
```

On KodeKloud, export the lab credentials first:

```bash
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=us-east-1
```

**And when the session is over — or before you close the laptop on a real
account — `terraform destroy`.**
