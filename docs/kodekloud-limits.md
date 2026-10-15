# KodeKloud AWS playground: fair-use limits

**Read this before sizing anything.** These are KodeKloud's *published* limits,
copied from <https://kodekloud.com/cloud-playgrounds/aws> on 2026-10-15. They are
a usage policy, not only IAM. Some are enforced as hard errors (SCPs). Others
are checked **after the fact** by a compliance job, which deletes the resource,
records a **violation against the account**, and can suspend the session or
restrict access to labs.

Re-read the page when starting a new playground; it changes.

## The limits

| Service | Limit | Exceed it and |
|---|---|---|
| Regions | us-east-1, us-west-2, us-east-2 only | refused |
| EC2 types | t2/t3 nano, micro, small, medium | refused (SCP) |
| EC2 CPU credits | **T-series must be `standard`. `unlimited` is forbidden** | instance reset, **session suspended/blocked** |
| EC2 size | max 2 vCPU and 4 GB per instance | refused |
| EC2 count | max 10 concurrent instances; **total 10 vCPU and 20 GiB** | violation |
| EC2 stopped | no more than 3 stopped instances | instances terminated |
| EC2 other | no Spot, Dedicated Hosts, Capacity Reservations, Scheduled Instances, VPN/TGW | refused |
| EBS | gp2/gp3 only, **max 30 GB per volume** | refused / violation |
| ECS | **max 2048 CPU units and 4096 MB memory** (account total) | **service deleted, violation recorded** |
| EKS roles | cluster `eksClusterRole`, node `AmazonEKSNodeRole`* | refused |
| EKS per pod | max 256 millicores CPU, 512 MiB memory | see below |
| EKS per namespace | max 3 pods | see below |
| EKS per cluster | 2000 millicores CPU, 4096 MiB memory (cumulative) | see below |
| EKS account-wide | 6000 millicores, 12288 MiB | see below |

\* The page says `AmazonEKSNodeRole`; the live boundary policy has only ever
permitted `eksWorkerNodeRole` (see `terraform/eks/variables.tf`). Trust the
live probe over the page.

## What has actually happened on this account

- **ECS, 2026-10-15: violation recorded.** The Artifactory task at 2048 CPU /
  **8192 MB** exceeded the 4096 MB cap. Five minutes after a successful apply,
  `assumed-role/OrganizationAccountAccessRole/ConfigRuleCheckerSession*` scaled
  the service to 0, stopped the task and deleted the service. A violation
  notice followed, with the warning that "serious or repeated violations may
  result in restricted access to labs." The size was chosen without reading
  this page first. That is the mistake this file exists to prevent.
- **EC2 credits.** The account default for t3 is `unlimited`. `terraform/aws`
  always pinned `standard`. `terraform/eks`'s node launch template did not until
  2026-10-15; the running nodes reported `standard` when checked.
- **EKS.** No EKS violation has been notified so far, but read literally the
  published pod caps are **below what this lab runs**:

  | Measured 2026-10-15, 5-node cluster | Published cap |
  |---|---|
  | total requests 1670m CPU, 2788 MiB | 2000m, 4096 MiB per cluster |
  | `jenkins-0` requests 1024 MiB | 512 MiB per pod |
  | 19 pods in `kube-system` | 3 per namespace |
  | build agent pod (BuildKit 512 MiB + others) | 512 MiB per pod |

  Whether these caps are enforced on self-managed EC2 nodes (as opposed to,
  say, Fargate pods) is not stated. Do not assume they are not.

## Rules for this repo

1. **Read the page first** when sizing anything new, and check every number
   against the table above, not against "what AWS allows".
2. **Fargate/ECS:** total across the account ≤ 2048 CPU / 4096 MB.
3. **T-series:** always `credit_specification { cpu_credits = "standard" }`.
4. **EC2:** 5 × t3.medium is already the full 10 vCPU / 20 GiB budget. Nothing
   else can run beside the EKS nodes.
5. **Volumes:** ≤ 30 GB, gp2/gp3.
6. **Anything that needs more** (Artifactory needs ~2 vCPU and more than 4 GB)
   does not belong on the playground. Run it elsewhere
   (`terraform/gcp-artifactory`) or not at all.
7. When something disappears, check CloudTrail for `ConfigRuleChecker` before
   debugging your own code.
