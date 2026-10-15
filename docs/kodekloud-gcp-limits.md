# KodeKloud GCP playground: fair-use limits

**Read this before sizing anything.** These are KodeKloud's *published* limits,
copied from <https://kodekloud.com/cloud-playgrounds/google> on 2026-10-15
(fetched with python `urllib`, User-Agent `Mozilla/5.0`, HTTP 200). The URL
`https://kodekloud.com/cloud-playgrounds/gcp` returns **404**; the right one is
linked from the AWS page and listed in `kodekloud.com/sitemap.xml`.
`https://kodekloud.com/playgrounds/google` redirects to it.

The AWS page's limits turned out to be enforced partly **after the fact**, by a
compliance job that deletes the resource and records a violation against the
account (`docs/kodekloud-limits.md`). The GCP page says nothing about
enforcement or violations, and that is no reason to assume they are not
enforced. Treat every line below as a hard limit.

Re-read the page when starting a new playground; it changes.

## The limits

| Service | Limit (as published) |
|---|---|
| **Allowed services** | Compute Engine, GKE, Load Balancing, VPC Network, Cloud NAT, Cloud Router, Cloud SQL, Cloud DNS, Artifact Registry, Cloud Storage, Cloud CDN, Cloud VPN. **Nothing else is listed: no Cloud Run, Cloud Build, Cloud Functions, App Engine or Secret Manager** |
| Regions | "All regions within US location" (Compute Engine) |
| Compute: machine series | **E2, N2** only |
| Compute: vCPU | **max 7 vCPU cores** |
| Compute: VMs | **max 5** |
| Compute: disk | **max 50G per disk, max 250G total**; Standard / Balanced / SSD |
| Compute: OS | Container-Optimized OS, Debian, Fedora, CentOS, Oracle Linux, Rocky Linux, Ubuntu |
| GKE | no Autopilot, no Enterprise tier, no GKE backup, no extended-support versions; **all Compute Engine limits apply to the nodes** |
| Load Balancing | 5 forwarding rules |
| VPC | 3 VPN tunnels, **8 external IPs**, flow-log sampling < 30% if enabled, **"Default VPC modification is not allowed"** |
| Cloud NAT | logging must be disabled |
| Cloud Router | max 2 routers |
| Cloud SQL | Enterprise edition only; SQL Server Express only; disk < 50GB; tiers db-f1-micro, db-g1-small, db-custom-1-3840, db-custom-2-7680, db-custom-2-8192 |
| Cloud DNS | 2 managed zones |
| Artifact Registry | allowed; **image scanning must be disabled** |
| Cloud Storage | no retention-policy lock on buckets or objects |
| Cloud CDN, Cloud VPN | allowed, no limits stated |

The page states no session duration and no memory cap separate from the vCPU
cap. An E2/N2 machine's memory follows from its type, so the vCPU limit is the
binding one.

## What the playground account looked like (probed 2026-10-15)

- `gcloud config list` pointed at project `kkgcplabs01-008`, **which the active
  account cannot see**. `gcloud projects list` returns only
  **`kkgcplabs01-034`**, so everything here uses `--project kkgcplabs01-034` /
  `-var project=kkgcplabs01-034`. The account was
  a generated `kk_lab_user_…` login.
- There is no application-default credential. Terraform authenticates with
  `GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)`, which is valid
  for one hour.
- APIs already enabled include `compute`, `container`, `artifactregistry`,
  `sqladmin`, `dns` and `storage`. **`run.googleapis.com` and
  `cloudbuild.googleapis.com` are not enabled.**
- Before anything was created: 0 VMs, 0 GKE clusters, 0 Artifact Registry
  repositories, only the `default` VPC. There was one leftover disk,
  `pvc-3aed1f35-...` (5 GB pd-balanced, us-central1-a, from an earlier GKE
  cluster). It was left alone, but it counts toward the 250G total.

## What runs here, against the limits

### Artifactory OSS 7.161.26 (`terraform/gcp-artifactory`), applied 2026-10-15

| Resource | Size | Limit | Project total after apply |
|---|---|---|---|
| VM `artifactory` | **e2-standard-2** (2 vCPU / 8 GiB), us-central1-a, Debian 12 | E2/N2, US region | **2 / 7 vCPU, 1 / 5 VMs** |
| Boot disk | 30G pd-balanced | ≤ 50G, balanced OK | **35 / 250G** (30 + the 5G leftover PVC disk) |
| Ephemeral external IP | 1 | 8 | 1 / 8 |
| VPC `artifactory-net`, subnet `artifactory-us-central1` (10.80.0.0/24) | new | VPC allowed; default VPC untouched | |
| Firewall `allow-artifactory-8082` | tcp/8082 from 0.0.0.0/0, **on `artifactory-net`** | | |

Two changes from the module as first written: the region default moved from
`europe-west3` (outside "US only") to `us-central1`, and the firewall rule moved
off `default` into its own VPC, because the page says "Default VPC modification
is not allowed". `region` and `machine_type` now have validation blocks for the
US-only and E2/N2 rules.

Cold start: first `200 OK` from `/artifactory/api/system/ping` came **263 s**
after `apply` finished (a 503 from the router from about 220 s). All nine
services reported `HEALTHY` on `/router/api/v1/system/health`.

#### The admin password: set by IaC, because REST could not do it

admin/admin is deliberate (throwaway lab, the user's choice). Every REST route
to change the password on a running **OSS** instance failed:

| Attempt | Result |
|---|---|
| `POST /artifactory/api/security/users/authorization/changePassword` (basic admin/password) | `400 "Incorrect username/password or the user might be locked"`, also when retried 60 s after the last failed login |
| `POST /artifactory/api/security/users/admin` | `400 "This REST API is available only in Artifactory Pro"` |
| `PUT /access/api/v2/users/admin/password`, basic auth | `401 "Unsupported authentication method Basic"` |
| same, Bearer from `POST /artifactory/api/security/token` | `401 "Invalid token, audience"`; asking for `audience=*@*` gives `400 "Only refreshable tokens with expiry can have custom audience"`, and the refreshable one is still `Invalid token, audience` |
| same, Bearer from the UI login cookie (`aud: jffe@*`) | `401 "Invalid token, audience"` |
| `/ui/api/v1/access/api/v2/users/admin[/password]` with the UI session | `403 Forbidden` |
| UI profile flow: `POST` then `PUT /ui/api/v1/ui/userProfile` | unlock `200`, update `403 Forbidden` |

Side effect worth knowing: each failed basic-auth attempt makes the next login
slow or refused for a while (a `403` for admin/admin, then UI logins hanging for
more than 120 s). Do not "just check" a password you are not sure of.

What worked was JFrog's documented bootstrap file. The startup script now
`docker create`s the container (which copies the image's content into the empty
volume), writes `admin@*=<admin_password>` to `etc/access/bootstrap.creds` in
the volume, owned by the image's uid and mode 600, then `docker start`s it. The VM was
replaced (`terraform apply -replace=google_compute_instance.artifactory`,
destroy then create, so never two VMs) to prove that from a clean boot:

```
admin/admin -> GET /artifactory/api/system/version
200 {"version" : "7.161.26", "revision" : "86126900", ..., "license" : "Artifactory OSS"}
```

`admin_password` is a sensitive variable with **no default**: pass
`TF_VAR_admin_password=admin`. It is stored in the local state (gitignored) and
in the VM's instance metadata, like the master key.

#### `generic-local` and a test upload

`PUT /artifactory/api/repositories/generic-local` is **Pro-only** on OSS:

```
400 "This REST API is available only in Artifactory Pro ..."
```

The UI's own endpoint works with an admin UI session
(`POST /ui/api/v1/ui/auth/login`, then):

```
POST /ui/api/v1/ui/admin/repositories
{"type":"localRepoConfig","typeSpecific":{"repoType":"Generic"},
 "general":{"repoKey":"generic-local"},
 "basic":{"includesPattern":"**/*","publicDescription":"lab test repo","layout":"simple-default"},
 "advanced":{}}
-> 200 {"info":"Successfully added repository 'generic-local'"}
```

`GET /artifactory/api/repositories` then listed `example-repo-local` and
`generic-local` (both LOCAL, Generic). Upload and read-back, as admin/admin:

```
PUT /artifactory/generic-local/smoke/hello.txt (67 bytes)
-> 201  "createdBy" : "admin",
        "sha256" : "f3fdf1d5608b39ba33010bdf604a502e0208dbfb6f5d605dd5af4f36b409358b"
GET /artifactory/generic-local/smoke/hello.txt
-> 200 'hello from platform-lab, uploaded to Artifactory on GCP 2026-10-15\n'
   sha256 of the download == sha256 of the local file: True
```

URL: `scripts/gcp-urls.sh` prints it from state. On 2026-10-15 it was
`http://34.173.186.193:8082` (ephemeral IP: it changes on stop/start or
replace).

## Backstage on Cloud Run: not deployed

**Cloud Run is not on KodeKloud's allowed-services list** (see the table), and
`run.googleapis.com` is not enabled on the project. Enabling an API for a
service the policy does not list is exactly the kind of step that produced the
AWS violation, so **nothing was created**: no API enabled, no Artifact Registry
repository, no image copy, no `terraform/gcp-backstage`. There is no denial
error to record because nothing was attempted.

Options that do fit the published limits, not done because they were not what
was asked:

- **Backstage on an E2 VM** (e.g. e2-medium, 2 vCPU / 4 GiB) beside Artifactory:
  4 / 7 vCPU and 65 / 250G in total. It would be plain HTTP, so the http-only
  workarounds in `ci/backstage/values.yaml` (notifications, `nav-content:app`,
  `upgrade-insecure-requests`) would apply again.
- **Backstage on a GKE Standard cluster**: allowed, but the nodes count against
  the same 7 vCPU, and Artifactory already uses 2.

Whatever runs it, two catalog facts from commit 9b3cdec apply: the catalog rules
must allow `[Component, System, Domain, API, Resource, Location, Group, User,
Template]` (without `Domain` the `delivery` domain is rejected), and the
`kubernetes:` block in `ci/backstage/values.yaml` (in-cluster service-account
auth to `https://kubernetes.default.svc`) only works inside EKS and must not be
copied. Expected entities after a refresh: 3 Groups, 1 Domain, 4 Systems,
7 Components, 1 API, 3 Resources, 1 Template, plus Locations.

## Rules for this repo

1. **Read the page first** when sizing anything new, and check every number
   against the table above, not against what GCP allows.
2. **A service that is not on the allowed list is not allowed**, even when the
   API can be enabled. Do not enable an API to find out.
3. **US regions only.** Every module validates `region` starts with `us-`.
4. **E2/N2 only, 7 vCPU across the whole project.** That includes GKE nodes.
   Add up every VM and node before applying.
5. **Disks ≤ 50G each, ≤ 250G total.** Count orphaned PVC disks too
   (`gcloud compute disks list`).
6. **Leave the `default` VPC alone.** Put firewall rules in a VPC you created.
7. **Artifact Registry: no image scanning.**
