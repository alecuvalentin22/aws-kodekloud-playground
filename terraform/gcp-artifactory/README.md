# terraform/gcp-artifactory -- Artifactory OSS on one GCE VM

**Status: ACTIVE (on demand).** The only place Artifactory has actually served
requests. Referenced by `scripts/gcp-urls.sh`, `scripts/app-urls.sh`, the
catalog and the docs as the chosen Artifactory home. No `make` target builds it.
It is the **KodeKloud GCP playground** stack, not AWS: it exists because
Artifactory could not run on the AWS playground (`terraform/ecs` hit the ECS
cap, EKS OOMKilled). Its GCP limits are in `docs/kodekloud-gcp-limits.md`.

## What it creates (`main.tf`)

- VPC `artifactory-net` (custom mode) and subnet `artifactory-<region>`
  (`10.80.0.0/24`); the `default` VPC is left alone (playground forbids changing it).
- Firewall `allow-artifactory-8082`: tcp/8082 from `allowed_cidrs`
  (**default `0.0.0.0/0`**), target tag `artifactory`.
- VM `artifactory`: `e2-standard-2` (2 vCPU / 8 GiB), Debian 12, 30 GB
  `pd-balanced` boot disk, ephemeral external IP. A startup script installs
  Docker and runs `artifactory-oss:7.161.26` (embedded Derby), with the admin
  password set through `bootstrap.creds`.
- Outputs: `url`, `note`. The IP changes on stop/start or replace.

Providers: `google ~> 6.0`, `random ~> 3.6`; `required_version >= 1.10`.
Variables: `project` (required, no default), `region` = `us-central1`
(validated `us-*`), `zone` = `us-central1-a`, `machine_type` = `e2-standard-2`
(validated E2/N2 only), `artifactory_version`, `allowed_cidrs`, `admin_password`
(sensitive, **no default**).

## State

**Local**, `terraform.tfstate` in this folder (gitignored; no backend block, by
design, "throwaway"). It holds the admin password and master/join keys in plain
text, so do not copy the folder or paste the state anywhere. This stack is
independent of the S3 bucket, so `make state` / `tf-init.sh` do not apply.

Trap: a new KodeKloud GCP playground is a **new project ID**
(`kkgcplabs01-0NN`). The old local state describes resources in a project that
no longer exists; a plan against the new project will fail or try to refresh
dead resources. Move the old `terraform.tfstate*` aside (or `terraform state rm`
them) before applying in a new project, and pass the new `-var project=...`.
This folder holds a state from the 2026-10-15 session (not inspected here).

## Who uses it

- `scripts/gcp-urls.sh` reads `terraform output url` from the local state;
  `scripts/app-urls.sh` shows it (`make urls`).
- `catalog/components.yaml` (Backstage `source-location`), `docs/ci-track.md`,
  `docs/kodekloud-limits.md` (rule 6), `docs/kodekloud-gcp-limits.md`
  (full applied walkthrough), `VERIFIED.md`, `playground/README.md`.
- **Not** in CI validate (`.github/workflows/ci.yml` lists aws, eks, bootstrap,
  eks-module, hetzner); `fmt -check` does cover it. Not in `make destroy`.

## Status evidence

Commits `0cb0ca1`, `327fb8f`, `05e12f4` (2026-10-15, applied and verified live),
`488bac7` (2026-10-16, jfconnect fix). Latest work in the folder.

## KodeKloud GCP fit (`docs/kodekloud-gcp-limits.md`)

| Limit | This stack |
|---|---|
| US regions only | `region` validated `us-*` (`main.tf:75`), default `us-central1` -- OK |
| E2/N2 only, max 7 vCPU, max 5 VMs | `e2-standard-2` validated `^(e2\|n2)-` (`main.tf:95`); 2 / 7 vCPU, 1 / 5 VMs -- OK. Add up any GKE nodes or other VMs before adding more |
| disk <= 50G each, <= 250G total | 30G `pd-balanced` -- OK (plus any orphaned PVC disks in the project) |
| 8 external IPs | 1 -- OK |
| default VPC must not be modified | own VPC and firewall -- OK |
| Artifact Registry scanning / Cloud Run etc. | not used -- OK |

Not a limit, but note: `allowed_cidrs` is open to the world and the admin
password is `admin` per the user's choice; throwaway only.

## How to run / destroy (from the repo root)

Needs: a GCP playground project, `gcloud` logged in, the Compute Engine API
enabled. No application-default credential on the playground, so use the user
token (valid one hour):

```bash
export TF_VAR_admin_password=admin
GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token) \
  terraform -chdir=terraform/gcp-artifactory init
GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token) \
  terraform -chdir=terraform/gcp-artifactory apply -var project=<project-id>
./scripts/gcp-urls.sh        # first 200 on /artifactory/api/system/ping after ~4.5 min
```

Destroy: same token, `terraform -chdir=terraform/gcp-artifactory destroy -var project=<project-id>`.
To rebuild the VM without ever having two: `apply -replace=google_compute_instance.artifactory`.
