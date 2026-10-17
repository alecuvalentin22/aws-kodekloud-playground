# Playground game console (Semaphore)

**Status: OPTIONAL (new, attach step not yet run).** The only Terraform in this
folder is `provider.tf` + `project.tf`: they configure a Semaphore *project*
(one project, one repository, one environment, 10 templates) through the
`semaphoreui/semaphore` provider `= 0.3.9`; `required_version >= 1.5.0`.
Nothing cloud is created. **Not a KodeKloud stack**: no AWS/GCP resources, no
playground limits apply. It only touches your local Semaphore at
`http://127.0.0.1:3000/api` (variable `api_base_url`).

- **State**: `backend "local" {}` with the path given at init
  (`-backend-config=path=$HOME/.local/state/platform-lab-playground/semaphore.tfstate`),
  deliberately outside the repo. Not S3, so `tf-init.sh` / `make state` do not
  apply and a new KodeKloud account changes nothing here.
- **Credentials**: `SEMAPHOREUI_API_TOKEN` in the environment (never in tfvars).
- **Used by**: only this folder's own docs and `roles/playground/defaults/main.yml`
  (image pin comment). No `make` target, script or CI job. CI does not validate
  it (`.github/workflows/ci.yml` lists other folders; `terraform fmt -check` covers it).
- **Evidence**: one commit, `2be3a5b` (2026-10-16). Its own table below says
  `terraform apply` against the live instance was not run.
- **Run / destroy**: the three-step "Attach it" block below (you run it; it
  restarts your Semaphore). Remove with `terraform -chdir=playground/semaphore
  destroy` using the same backend path.

Buttons for `playground/play`. The candidate investigates in his own terminal
(Jenkins, `kubectl`, `git`); Semaphore starts incidents, gives hints, checks
fixes and keeps the history. **Red task = not fixed yet. Green = solved.**

This is **not a second Semaphore**. It adds one project, `playground`, to the
instance `gcp-setup/local/semaphore` already runs, and extends that instance's
image with two tools.

| Template | Runs | Notes |
|---|---|---|
| 1. Start drill | `tasks/start.sh` → `play start …` | survey: drill (01–08 or random/blind), track, tier |
| 2. Status | `play status` | elapsed time, hints used |
| 3. Hint (-15) | `play hint` | next hint |
| 4. Check my fix | `play check` | red until really fixed; green prints the score |
| 5. Reveal (give up) | `play reveal` | root cause + "say this in the interview" |
| 6. Reset to baseline | `play reset` | new commits, never a force-push |
| 7. Scoreboard | `play score` | |
| 8. Doctor | `play doctor` | is the playground reachable from Semaphore? |
| 9. List drills | `play list` | |

`play close` stays in the terminal: it opens an editor, and a task has none
(see `ENGINE-CHANGES.md` §1).

## How values reach the scripts (Semaphore v2.19.12, from its source)

- A bash template runs as `bash <playbook> [template arguments] [name=value …]`:
  survey answers are appended as `name=value` arguments
  (`services/tasks/local_executor.go`, `getShellArgs`). `tasks/_env.sh`
  parses only known names and `start.sh` checks every value against an allowlist.
- Environment variables come from the project **environment** (`project.tf`),
  not from compose: a task inherits only `PATH` from Semaphore's own process
  (`db_lib/LocalApp.go`, `getEnvironmentVars`).
- `HOME` is a per-template directory (`db_lib/ShellApp.go`), so no path may be
  derived from `$HOME`; `PLAYGROUND_STATE` / `PLAYGROUND_WORK` are explicit.
- A local-path repository runs **in place** (`db/Repository.go`, `GetFullPath`):
  tasks execute the mounted checkout directly, no clone.

## Attach it (you run these; they restart YOUR Semaphore)

Prerequisites: the playground is up (`playground/setup/up.sh`), and the
gcp-setup image `valensys-semaphore:2.19.12` exists (it does once gcp-setup's
`start.sh` has run). The restart keeps the same Compose project, volume and
database -- it is the same "rebuild" gcp-setup's `start.sh` does.

```bash
cd ~/gcp/platform-lab

# 1. a kubeconfig that works from inside the kind network (mode 600)
playground/semaphore/kubeconfig.sh

# 2. rebuild + restart the ONE instance with the override layered on
export SEMAPHORE_ENV_FILE=/path/to/your/private/credentials.env   # the gcp-setup one
export SEMAPHORE_REPOSITORY_PATH="$HOME/gcp/gcp-setup"
export PLATFORM_LAB_PATH="$HOME/gcp/platform-lab"   # gcp-setup's compose already mounts it at /platform-lab
export PLAYGROUND_STATE_HOST="$HOME/.local/state/platform-lab-playground"
export PLAYGROUND_WORK_HOST="$HOME/platform-playground"
docker compose --project-name valensys-t2-semaphore --env-file "$SEMAPHORE_ENV_FILE" \
  -f ~/gcp/gcp-setup/local/semaphore/compose.yaml \
  -f playground/semaphore/compose.override.yaml up -d --build

# 3. the project, as code (state outside the repo)
export SEMAPHOREUI_API_TOKEN=...        # an API token for that instance
terraform -chdir=playground/semaphore init \
  -backend-config=path="$PLAYGROUND_STATE_HOST/semaphore.tfstate"
terraform -chdir=playground/semaphore apply
```

Then open http://127.0.0.1:3000 → project **playground** → **8. Doctor**: it
should print four green ticks.

**One thing to keep in mind:** gcp-setup's own `start.sh` / `manage.py setup`
rebuild with only `compose.yaml`. After that, the playground templates fail
fast with "kubectl missing: is this the playground image?" until the command
in step 2 is run again. Either always start the instance with both `-f`
files, or add the override to gcp-setup's `start.sh` -- your call; nothing here
edits gcp-setup.

## What was verified, and what was not (2026-10-16)

| Claim | Status |
|---|---|
| `terraform fmt -check`, `init -backend=false`, `validate` (provider 0.3.9) | **verified** in a scratch copy |
| `bash -n` on every script | **verified** |
| Image builds FROM `valensys-semaphore:2.19.12`; kubectl v1.34.11 + terraform 1.14.4 in `/opt/playground/bin`; gcp-setup's terraform 1.10.5 untouched; runs as uid 1001 | **verified** (`docker build -t playground-semaphore:dev`) |
| uid 1001 can read the mode-600 files in the mounted state dir (Docker Desktop for Mac) | **verified** with a throwaway container. Not true on a Linux host |
| Wrappers run as Semaphore would run them -- uid 1001, cwd = mounted repo, HOME elsewhere, on the `kind` network, env as in `project.tf`: `doctor` reaches cluster, Gitea, Jenkins and registry (rc 0); bad command / drill / track / injection attempts refused (rc 2); missing env fails with one clear line | **verified** in throwaway containers from the dev image |
| `terraform apply` against the live instance, templates appearing, survey rendering, a task run from the UI | **not run**: the instance is yours and may be in use; attaching it is the steps above |
| `start` / `check` / `reset` from Semaphore end to end | **not run** from Semaphore (they mutate the shared game state); the same engine is verified from the terminal |
| tier `aws` from Semaphore | **not wired**: needs the AWS credentials and EKS kubeconfig mounted too |
