# Tracker: every drill as a ticket on a Jira-like board

The candidate's work at the new job will arrive as Jira tickets on a board. So
the drills do too: one ticket per drill and per exercise, grouped into the
days of [GUIDE.md](../GUIDE.md), on a self-hosted **Plane** board on the home
lab. The ticket is where she reads the incident and how to start it; `play`
moves the ticket as she goes.

| | |
|---|---|
| Board | http://tracker.192.168.0.23.nip.io/interview-prep/ (tile "Tracker" on the start page) |
| Login | `admin@homelab.local` / the shared lab password (Plane logs in by e-mail) |
| Project | **Interview prep**, key `PREP` (tickets `PREP-1`, `PREP-2`, ...) |
| Deployment | `homelab/platform/apps/80-plane.yaml`, details in [homelab/platform/README.md](../../homelab/platform/README.md#tracker-plane) |

## Why Plane

Requirement: it must look and work like Jira (board, backlog, epics, issue
view, statuses), run on the home lab, have a REST API a script can drive, be
free and open source, and fit next to Jenkins and Artifactory.

| Tool | Jira look and feel | Self-hosted footprint | API for a script | Licence | Verdict |
|---|---|---|---|---|---|
| **Plane CE** (chosen) | Close: board / list / spreadsheet / calendar / Gantt layouts, backlog, states with groups, labels, priorities, cycles (= sprints), modules (= epics; the Epic type itself is paid), issue view with activity and comments | Official Helm chart `plane-ce`; 11 pods (web, space, admin, live, api, worker, beat, PostgreSQL, Valkey, RabbitMQ, MinIO); **~1.1 GiB measured** here | REST `/api/v1`, API keys, `external_id` on items (idempotent sync) | AGPL-3.0 | Most Jira-like modern OSS option with a chart |
| OpenProject | Partly: work packages typed Epic/Feature/Story, backlogs, basic boards (action boards are Enterprise); feels like MS Project / Redmine | Official Helm chart; Rails + PostgreSQL + memcached; vendor says 4 GiB for the all-in-one | REST v3 (HAL), good | GPL-3.0 | Heavier, less Jira-like |
| Taiga | Scrum/Kanban, epics, user stories; its own vocabulary | ~9 containers (back, front, events, async, 2x RabbitMQ, PostgreSQL, protected, gateway); docker-compose only, no official chart | REST, good | MPL-2.0 | Workable; slow upstream, no chart |
| Redmine | No: issue list + Gantt; boards need (paid) plugins; 2008 look | Light (one Rails pod + DB); Bitnami chart is deprecated | REST, good | GPL-2.0 | Not the layout she will use |
| YouTrack | Very close (agile boards, epics, sprints, query language) | One JVM container, ~1.5-2 GiB | REST, excellent | Proprietary, free up to 10 users | Not open source |
| Huly | Linear-like | Heavy: 15+ services (CockroachDB, Elasticsearch, MinIO, Redpanda...), 8+ GiB | No simple REST (platform SDK / WebSocket) | EPL-2.0 | Too heavy for the lab |
| Leantime | No: kanban + milestones aimed at non-project-managers | Light (PHP + MySQL) | JSON-RPC | AGPL-3.0 | Not Jira-like |
| *Jira Cloud Free* | *It is Jira* | *Cloud, Atlassian account, data off the lab* | *REST v3, excellent* | *Proprietary, free up to 10 users* | *The alternative if the real thing matters more than local; sync.sh would need its API instead* |

Footprints other than Plane's are vendor figures or the shape of their official
install, not measured on this lab.

## What she sees

- **Modules = epics**, one per day of the plan: Day 1 Jenkins pipelines (01,
  02), Day 2 Terraform and Kubernetes (08, 03), Day 3 Jenkins agents and safety
  (05, 04), Day 4 Blast radius and access (07, 06), Day 5 home-lab tier (21, 24
  + the platform tour), Day 6 AWS (every AWS-tier drill), Day 7 mock interview, GitHub tier
  (31-34), More local drills (every other local drill: 09, 41+), Exercises. The board can be grouped or
  filtered by module (Display -> Group by -> Modules), like Jira's epic swimlanes.
- **One ticket per drill**, `NN — <title>`: the developer's message (the
  `ticket.md` text), how to run it (`play start NN`, and where: the lab box, the
  Mac, AWS or GitHub), par, level as priority, labels `track:*` / `tier:*` /
  `unverified`, and a link to the ticket in GitHub. **Never the hints or the
  solution**: those stay behind `play hint` / `play reveal`.
- **Statuses** follow the game: Todo -> **In Progress** (`play start NN`) ->
  **Done** (`play check` says SOLVED; the score, time and hints become a
  comment) -> `play close` posts her journal entry as a comment. `play reveal`
  while a drill is running (giving up) moves it to **Needs replay**, adds the
  label `revealed` and comments. `play reset` changes nothing on the board.
- A **random** drill (`play start` with no ID) is not moved to In Progress:
  that would tell her which drill it is. It moves to Done when she solves it.

## Set up (once)

1. **One command, from the Mac in this repo** (re-run whenever drills are added;
   it updates, never duplicates, and never moves a ticket's status):

   ```bash
   playground/tracker/sync.sh --check     # optional: can it reach Plane? how many tickets?
   playground/tracker/sync.sh
   ```

   The API token is automatic: when `~/.config/platform-lab/tracker.env` is
   missing, or Plane no longer accepts its token, `sync.sh` runs
   [`token.sh`](token.sh), which gets the token server-side (Django shell in the
   `plane-api` pod through the home-lab kubeconfig, no browser), writes the file
   (mode 600: `TRACKER_URL`, `TRACKER_WORKSPACE`, `TRACKER_PROJECT`,
   `TRACKER_TOKEN`) and prints only that it did. There is exactly one token,
   labelled `platform-lab sync`, for the admin user: it is reused, never piled
   up (duplicates with that label are deleted, the oldest is kept). Plane's
   admin account must exist first (`homelab/platform/plane-setup.sh admin`,
   done once by the lab owner).

   Without kubectl access to the lab, create a token by hand instead: log in,
   open http://tracker.192.168.0.23.nip.io/settings/profile/api-tokens/
   (avatar -> Settings -> Personal access tokens), and write the file:

   ```bash
   mkdir -p ~/.config/platform-lab && chmod 700 ~/.config/platform-lab
   ( umask 077; cat > ~/.config/platform-lab/tracker.env ) <<'EOF'
   TRACKER_URL=http://tracker.192.168.0.23.nip.io
   TRACKER_WORKSPACE=interview-prep
   TRACKER_PROJECT=PREP
   TRACKER_TOKEN=paste-it-here
   EOF
   ```

2. **The hook on the lab box** (local drills run there): copy the same file,
   `ssh homelab-1-wsl 'mkdir -m 700 -p .config/platform-lab' && scp -p
   ~/.config/platform-lab/tracker.env homelab-1-wsl:.config/platform-lab/`.
   Without the file `play` behaves exactly as before. On the Mac the file is
   already there, so `playground/play` runs from the Mac (home-lab, AWS and
   GitHub tiers) move tickets too, **including test runs**: to play without
   touching the board, `TRACKER_ENV=/nonexistent playground/play ...`.

## How the hook works

`playground/lib/tracker.sh <event> <drill-id> [text|file]`, called from `play`
through one helper line (`tracker() { "$PG_ROOT/lib/tracker.sh" "$@" || true; }`)
in four places: `start` (In Progress), `check` on SOLVED (Done + comment),
`close` (journal comment), `reveal` while running (Needs replay + comment).
It does nothing unless `~/.config/platform-lab/tracker.env` exists or
`TRACKER_URL` is set; every request has a 5 s ceiling, it stops at the first
failure, prints one warning and always exits 0, so a tracker that is down never
breaks the game. Items are found by `external_id` (`drill-NN`, source
`platform-lab-playground`), not by title, so renaming a ticket in the UI is safe.

## Not built: starting a drill from the board

Plane can send webhooks (workspace settings -> Webhooks) on work-item updates,
so "drag the ticket to In Progress = `play start NN`" is possible in principle:
a small receiver on the box would check the signature (`X-Plane-Signature`,
HMAC-SHA256 of the body with the webhook secret), map `external_id` to the
drill and run `play start`. It is not built, on purpose: the receiver would
have to be reachable from the cluster, which means a new listening port on the
box (the brief allows no new port beyond the Ingress); `play start` prints the
ticket and the clock into a terminal she would not be looking at; and a drag
would start a drill on the shared playground with no confirmation. The game is
started from the terminal; the board only follows it.
