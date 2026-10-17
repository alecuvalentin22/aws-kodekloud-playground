# terraform/eks-module -- EKS via the community module (reference only)

**Status: LEGACY / reference. Do not apply on a KodeKloud account.**
Nothing runs it: no `make` target, no script, no drill. It is built and
validated in CI and described in the README as "the same cluster via
`terraform-aws-modules/eks`, and why it cannot be used on a locked-down
account". `terraform/eks` is the stack that is actually used.

## What it creates (`main.tf`)

- IAM: roles `eksClusterRole` and `eksWorkerNodeRole`, an instance profile
  `eksWorkerNodeRole`, and the policy attachments (4 on the node role).
- `module "eks"` (`terraform-aws-modules/eks/aws ~> 21.0`): cluster
  `<prefix>-eks` (default `andrei-lab-eks`), Kubernetes `1.33`, public endpoint
  limited to `public_access_cidrs` (required, `0.0.0.0/0` rejected), KMS,
  CloudWatch log group and managed IAM role turned off (denied on the playground),
  one **self-managed** node group `default` (t3.medium, desired 2, min 1, max 3).

Providers: `aws ~> 6.0` (the module needs >= 6; the other stacks use `~> 5.0`).
Outputs: `cluster_name`, `cluster_endpoint`, `kubeconfig_command`.
`terraform.tfvars` (gitignored) only sets `public_access_cidrs`.

## State

S3, `backend.tf`: key `platform-lab/eks-module/terraform.tfstate`, bucket
`andrei-lab-tfstate-<account-id>` supplied by `./scripts/tf-init.sh eks-module`.
`make state` leaves it alone (LEGACY; not in Makefile `STATE_STACKS`). New KodeKloud
account = new bucket = re-init needed. Its `.terraform/` was last touched
2026-08-19, so it currently points at an old account's bucket until re-inited.

## Who uses it

- `.github/workflows/ci.yml`: `fmt` and `validate` only (`init -backend=false`).
- `Makefile` `STATE_STACKS` (init only).
- Docs: `README.md` (table of folders), `STORY-AWS.md`, `terraform/eks/main.tf`
  comments, AGENTS.md section 5 ("Do not reach for terraform-aws-modules/eks on
  this account").

## Status evidence

One commit: `ad8d4b2` (2026-08-19, "Self-managed EKS nodes"), the day it was
tried. AGENTS.md records why it fails here: the module hardcodes
`bootstrap_cluster_creator_admin_permissions = false` and grants admin through
`eks:AssociateAccessPolicy`, which is DENIED, so you get running nodes and no
principal able to administer the cluster. (Note `main.tf` sets
`enable_cluster_creator_admin_permissions = true`; whether that is enough on the
live account is not shown anywhere in the repo.)

## KodeKloud fit -- flags

- **T-series credits not pinned.** `self_managed_node_groups.default`
  (`main.tf:170-188`) sets no `credit_specification`. The account default for t3
  is `unlimited` (`docs/kodekloud-limits.md`), and `unlimited` gets the session
  suspended. `terraform/eks` and `terraform/aws` pin `standard`; this one does not.
  Would likely violate the limit if applied unchanged.
- **Collides with `terraform/eks`.** Same cluster name (`andrei-lab-eks`) and the
  same fixed IAM role names (`eksClusterRole`, `eksWorkerNodeRole`). It cannot
  coexist with `terraform/eks` in one account.
- EC2: `t3.medium` (variables.tf), max 3 nodes = 6 vCPU / 12 GiB, within budget
  alone. Root volume: module default, not set here.
- Does not open NodePorts, so none of the lab services would be reachable.

## How to run / destroy

Do not, on KodeKloud. In your own AWS account:

```bash
./scripts/tf-init.sh eks-module
cd terraform/eks-module && terraform apply   # needs public_access_cidrs in terraform.tfvars
terraform destroy
```

If you do want to try it on a playground, first add `credit_specification =
{ cpu_credits = "standard" }` to the node group and destroy `terraform/eks`
first (shared names). Nothing in this README was verified by running terraform.
