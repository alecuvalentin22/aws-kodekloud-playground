# terraform/bootstrap -- the S3 state bucket

**Status: ACTIVE.** Run for you by `scripts/tf-init.sh`, which `make state`
calls once per stack. You almost never `cd` in here.
Not KodeKloud-limited (one S3 bucket, no compute). AWS only.

## What it creates

Only the bucket that every other S3-backed stack keeps its state in
(`main.tf`):

- `aws_s3_bucket.state`, named **`<prefix>-tfstate-<account-id>`**
  (default `andrei-lab-tfstate-<account-id>`; the account ID makes the global
  S3 name unique and the apply reproducible), `force_destroy = true` by default.
- versioning on, AES256 encryption, public access fully blocked, and a
  lifecycle rule that expires old state versions after 30 days.

Providers: `aws ~> 5.0`, `random ~> 3.6` (declared, not used by any resource);
`required_version >= 1.10`.
Variables (`variables.tf`): `region` = `us-east-1`, `prefix` = `andrei-lab`,
`force_destroy` = `true`.
Outputs (`outputs.tf`): `state_bucket`, `region`, `init_command`.

## State

**Local, on purpose** (no `backend` block): the bucket cannot hold its own
state. Files live in this folder (`terraform.tfstate`, `.backup`), all
gitignored.

The trap: that local state remembers the bucket of whichever account ran it
last. A **new KodeKloud account = new account ID = new bucket name**, so the old
local state points at a bucket the new account does not own. `scripts/tf-init.sh`
does not handle this; the folder here holds a
`terraform.tfstate.acct-<id>.bak`, i.e. the previous account's state was set
aside by hand. On a new account, move the old `terraform.tfstate*` aside
(do not delete the only copy until you are sure) before running `make state`.
Not verified by running it -- terraform was off limits when this was written.

## Who uses it

- `scripts/tf-init.sh` runs `terraform -chdir=terraform/bootstrap init` then
  `apply -auto-approve`, then reads the `state_bucket` and `region` outputs.
- `make state` -> `scripts/tf-init.sh <stack>` for each of `aws eks ecs
  eks-module` (Makefile `STATE_STACKS`) -- so bootstrap is applied (a no-op
  after the first time) once per stack.
- `drills/10-terraform-state.md` (the chicken-and-egg explained),
  `.github/workflows/ci.yml` (`fmt` + `validate` only, no backend),
  `catalog/resources.yaml`.

## Status evidence

Last commit touching it: `04ce2b7` (2026-08-18). Nothing has needed changing
since; every S3-backed stack depends on it.

## KodeKloud fit

Fine. No EC2/EBS/ECS/EKS. Region is `us-east-1` (allowed list:
us-east-1, us-east-2, us-west-2). S3 is permitted on the playground
(`docs/kodekloud-limits.md` does not list S3 as limited; AGENTS.md says EC2,
S3, RDS, VPC are granted).

## How to run / destroy

Normally do not run it by hand; use the wrapper (from the repo root):

```bash
# credentials loaded in the shell first, see terraform/README.md
export LAB_ACCOUNT_IDS=<account-id>   # otherwise tf-init.sh asks you to type it
make state                            # = ./scripts/tf-init.sh for aws eks (STATE_STACKS)
# or just one stack:
./scripts/tf-init.sh eks
```

`tf-init.sh` refuses to continue if the caller's account is not in
`LAB_ACCOUNT_IDS` (or you do not type the account ID at the prompt).

Destroy: nothing in the Makefile destroys it (`make destroy` only does eks and
aws). On a playground the bucket dies with the account. In a real account
destroy the other stacks first, then `terraform -chdir=terraform/bootstrap
destroy` (works because `force_destroy = true`).
