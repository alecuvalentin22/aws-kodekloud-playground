# The GitHub tier (drills 31-34)

Real GitHub, real Actions, real GHCR, on **your own account**. The job description
asks for "GitHub for source control, branching workflows, and pipeline triggers" and
"shared/reusable pipeline patterns"; GitLab, Bitbucket, Gitea and Jenkins are not
the same product, and an interview question about GitHub is answered from having
done it. These four drills are that practice.

| ID | Ticket | What it trains |
|---|---|---|
| 31 | "My PR has no checks" | `on:` triggers, path filters, why `pull_request_target` is the wrong fix |
| 32 | "Can't merge: 'build' expected" | branch protection, required check names, matrix names, no admin override |
| 33 | "Every repo red after a shared workflow change" | reusable workflows, `@main` vs tag/SHA, revert forward, releases (GitHub analog of drill 07) |
| 34 | "Publish job: 403 pushing to GHCR" | `GITHUB_TOKEN` permissions, job-level least privilege, GHCR |

## What it creates (and what it never touches)

Three **public** repositories under your user, from `playground/github-template/`.
Public because branch protection on private repos needs a paid plan on a free
account, and Actions minutes are free on public repos.

| Repo | Role |
|---|---|
| `playground-workflows` | the platform team's reusable workflow (`python-lint.yml`, `workflow_call`), tagged `v1.0.0`; no protection (so the drills' mistakes are possible) |
| `playground-demo-api` | a small Flask service, `ci.yml` (lint via the shared workflow, tests, publish an image to `ghcr.io/<you>/playground-demo-api`); **`main` is protected** |
| `playground-search-api` | the same app, a second caller of the shared workflow (so a break there is a blast radius) |

Baseline protection on `playground-demo-api` `main`: pull request required (0
approvals: you are the only human), **admins included**, no force-push, no deletion,
no required checks (drill 32 adds one). Every repo has Actions on and the default
`GITHUB_TOKEN` read-only.

It never touches the repo this code lives in, or any repo you own that is not one of
those three: every playground repo carries the description `platform-lab playground: ...`
and the topic `platform-lab-playground`. `up-github.sh` refuses to adopt, and `--destroy`
refuses to delete, a repo of that name without the marker.

## The token

One file, mode 600, never in git, never printed:

```bash
mkdir -p ~/.config/platform-lab
cat > ~/.config/platform-lab/github-playground.env <<'EOF'
GITHUB_TOKEN=ghp_paste_the_token_here
GITHUB_OWNER=your-github-login
EOF
chmod 600 ~/.config/platform-lab/github-playground.env
```

It is read by `lib/github.sh` (parsed, not sourced) and by `lib/git-credential-github.sh`.
`curl` gets it through a `-K` config read from a pipe, `git` through a credential helper:
it is never in argv, a URL, `.git/config` or a keychain. Use a **dedicated** token you
can revoke when you are done.

**Create it:** GitHub > Settings > Developer settings > Personal access tokens >
**Tokens (classic)** > Generate new token (classic). Name it `platform-lab playground`,
expiry 30 days, and tick:

| Scope | Needed for |
|---|---|
| `repo` | creating the repos, branch protection, pull requests, reading runs and check runs, dispatching CI, `git push` |
| `workflow` | pushing anything under `.github/workflows/` (all four drills do; the first push fails without it) |
| `read:packages` | drill 34's check: is the image tag in GHCR |
| `delete_repo` | `up-github.sh --destroy` |
| `delete:packages` | `--destroy` removing the GHCR packages |

Without `read:packages` drill 34 still works (it trusts the green publish job and says
so). Without `delete_repo`/`delete:packages`, delete the repos and packages by hand.

Fine-grained tokens: not recommended. The packages API does not accept them, and
creating/deleting repos with one depends on account settings. If you try: Administration,
Contents, Pull requests, Actions, Workflows read-and-write on All repositories.

## Set up

```bash
playground/setup/up-github.sh --selftest    # offline; parsing/jq tests, no network
playground/setup/up-github.sh               # idempotent; ~5 min the first time
playground/play list
playground/play start 31                    # or: play start --tier github
```

`up-github.sh` validates the token (`GET /user`, scopes), creates the repos from the
template and pushes the initial commit (default branch `main`, tags `baseline`, and
`v1.0.0` on the shared repo), turns Actions on, sets the default `GITHUB_TOKEN` to
read-only, applies the protection, waits for the baseline CI on `main` to be green in both
app repos (the first publish creates the GHCR package), and clones everything into
`~/platform-playground-github/`. Work there. State is in
`~/.local/state/platform-lab-playground/github`. Re-running it only repairs.

**Pin the actions first (recommended):** the template uses version tags
(`actions/checkout@v4`, `actions/setup-python@v5`). Before the first `up-github.sh`:

```bash
playground/setup/up-github.sh --pin-actions   # read-only API calls; rewrites the template to full SHAs
git diff playground/github-template           # review, commit
```

## How a drill works

`play start` runs `lib/preflight-github.sh` (token valid, repos and clones exist,
protection and CI back at baseline), then the drill's `break.sh`, which acts as a
"teammate": commits from a scratch clone under a different author name. On the
protected `main` it switches `enforce_admins` off for the push and **straight back
on**, because that is the owner's bypass and the only way a harness running as you can
push there. `check.sh` asks the API (runs, check runs, the protection, PRs, GHCR
versions) and reads the workflow files as text for the penalties.

`play reset` (= `lib/reset-github.sh <id>`, or `up-github.sh --reset` for all) closes
open PRs, deletes every branch but `main`, re-applies the protection, puts each repo's
tree back to `baseline` **as a new commit**, deletes stray tags, restores `v1.0.0`/`baseline`
if they were moved, and waits for green CI. It then fast-forwards your clones if they are
clean on `main`. `main` is never force-pushed.

## Gotchas

- **An orphan package blocks the push.** A GHCR package outlives its repo. If you delete a
  playground repo by hand (not with `--destroy`) and recreate it, the existing package is not
  linked to the new repo, and its `GITHUB_TOKEN` gets 403 even with `packages: write`; the
  baseline CI then goes red at `publish`. Delete the package
  (github.com > your profile > Packages > the package > Settings > Delete) and re-run.
- **Rate limits.** 5,000 API calls/hour for a token; a drill uses ~100. `lib/github.sh`
  sleeps through short limits and says when a long one ends.
- **First `git push` asks for a password?** The credential helper only answers for
  `github.com` and only if the env file is mode 600. Check `git config --get-all credential.helper`
  in the clone: it should end with `.../lib/git-credential-github.sh`.
- **Template changes do not reach existing repos.** `--destroy`, then `up-github.sh`.
- Drills are `VERIFIED=no` until played against real GitHub (see each `drill.env`).

## Remove it

```bash
playground/setup/up-github.sh --destroy       # asks you to type your login; --yes to skip
rm -rf ~/platform-playground-github           # your clones, if you want them gone
rm ~/.config/platform-lab/github-playground.env   # and revoke the token on GitHub
```
