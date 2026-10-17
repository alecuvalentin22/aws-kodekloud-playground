# terraform/ecs -- Artifactory OSS on ECS Fargate (superseded)

**Status: LEGACY.** Nothing in the Makefile, `scripts/`, CI or the playground
runs it. It is referenced only from docs as the story of what failed.
Superseded by `terraform/gcp-artifactory` (a GCE VM), which is the Artifactory
that actually serves requests. KodeKloud AWS playground; **this is the stack
that earned the recorded violation** (see below), so do not resize it.

## What it creates (`main.tf`)

- ECS cluster `<prefix>` (default prefix `platform-lab`).
- Task definition `artifactory-oss`: Fargate, `cpu = "2048"`, `memory = "4096"`,
  30 GiB ephemeral storage, image
  `releases-docker.jfrog.io/jfrog/artifactory-oss:7.161.26` (embedded Derby, keys
  from `random_id`). No IAM role, no log driver (a playground restriction), so a
  dead app inside a RUNNING container leaves no trace.
- ECS service `artifactory` (1 task, public IP in the default VPC subnets) and a
  security group opening tcp/8082 to `ui_cidrs` (**default `0.0.0.0/0`**).
- Output `how_to_find_the_url` (the task IP changes on every start).

Providers: `aws ~> 6.0` (the others use `~> 5.0`), `random ~> 3.6`;
`required_version >= 1.10`. Variables: `region`, `prefix`, `artifactory_version`,
`ui_cidrs`.

## State

S3, `backend.tf`: key `platform-lab/ecs/terraform.tfstate`, bucket
`andrei-lab-tfstate-<account-id>` supplied by `./scripts/tf-init.sh ecs`.
New KodeKloud account = new account ID = new bucket, so `.terraform/` here must be
re-initialised: `./scripts/tf-init.sh ecs`. `make state` does not include `ecs`
(LEGACY; `make state STATE_STACKS=ecs` if you ever need it).

## Who uses it

Nobody runs it. Mentions only: `docs/ci-track.md` (the "why ECS for one thing and
EKS for another" answer), `VERIFIED.md`, `ci/artifactory/artifactory.yaml`
(comment: "terraform/ecs runs the same image on Fargate and is the cleaner design
in a normal account"). It is **not** in `make destroy` and **not** in CI
validate (`.github/workflows/ci.yml` checks aws, eks, bootstrap, eks-module,
hetzner only; `terraform fmt -check` does cover it).

## Status evidence

Commits all on 2026-10-15: `eab4bb4` (created), `7c50d3f`, `bf77646` ("Artifactory
moves to EKS on the playground"), `327fb8f`. Same day the work moved to EKS and
then to GCP. The history in the file header: 1 vCPU timed out (access service
took 364 s), 2 vCPU / 8 GB was deleted by the compliance job, and the current
2048 / 4096 "was NOT tried before the stack was destroyed". So it has never
served a request.

## KodeKloud fit (`docs/kodekloud-limits.md`)

- **ECS cap = 2048 CPU units and 4096 MB, account-wide.** The code sits exactly
  on the cap (`main.tf:113-114`). It is allowed, but there is zero headroom: any
  other Fargate task in the account would breach it. The earlier 2048 / 8192
  version triggered `ConfigRuleCheckerSession` deleting the service within 5
  minutes and a violation against the account (2026-10-15). Never raise these.
- Fargate ephemeral storage 30 GiB (`main.tf:117`) is not an EBS volume but is at
  the same 30 number; there is no published ephemeral cap.
- Even within the cap, 4096 MB may not be enough (the same image was OOMKilled at
  3 GiB on EKS). A task that dies silently still counts as a failed experiment;
  prefer `terraform/gcp-artifactory`.
- Open security group on 8082 (`variables.tf` `ui_cidrs`) with the default admin
  login: acceptable only for a throwaway.

## How to run / destroy (only if you really want the experiment)

```bash
# credentials in shell, LAB_ACCOUNT_IDS set (see terraform/README.md)
./scripts/tf-init.sh ecs
cd terraform/ecs && terraform apply     # about 4 min before the first 200 on :8082
# find the IP: aws ecs list-tasks --cluster platform-lab --service-name artifactory
terraform destroy
```

`make destroy` does not touch it, so destroy it yourself before the session ends.
