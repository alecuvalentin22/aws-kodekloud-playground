# Exercise: Backstage, onboarding a service (45 to 60 minutes)

Not a scored drill: no clock, nothing breaks. You **put a new service on the
developer portal yourself**, repair an entity that Backstage silently refuses, and
learn how the platform team would extend the portal. Afterwards you can talk about
*"Support and extend Backstage as the team's developer portal"* from hands-on
experience, not from the docs.

| Part | What you do | Minutes |
|---|---|---|
| 0 | Set up, a public GitHub repo, first look | 10 |
| 1 | Understand the catalog model by reading the live catalog | 10 |
| 2 | Onboard a new service: write `catalog-info.yaml`, get it into Backstage | 15 |
| 3 | Find and fix a deliberately broken entity | 15 |
| 4 | How would you extend Backstage? (read and describe, nothing to build) | 5 |
| 5 | `./check.sh`, say it out loud, clean up | 5 |

You need: the Mac terminal in this repo, the home Wi-Fi, a **GitHub account** with a
**public** repository you can push to (a throwaway one is fine), and `git`.
No password: Backstage lets everyone in as "guest".

---

## 0. Set up

```bash
cd playground/exercises/backstage
export EX_PREFIX=candidate     # the name of everything you create; change it to start over
```

`EX_PREFIX` may only use lower-case letters, digits and `-`.

**A public repository.** Create one on GitHub, for example `orders-service`, with
**Public** visibility and an initial commit (tick "Add a README"). Clone it somewhere
outside this repo:

```bash
git clone git@github.com:<your-user>/orders-service.git ~/orders-service
```

> Why public? Backstage reads your file from GitHub **without a token** (this lab has
> none configured), and GitHub only serves public repositories without one. A private
> repository would answer "not found". See "How a file reaches Backstage" in part 2.

**First look.** Open http://backstage.192.168.0.23.nip.io and press **Enter**
(guest sign-in). The catalog is the home page (`/`, not `/catalog`). Then, in the
terminal, meet the helper:

```bash
./bs.sh get component demo-api
```

`bs.sh` talks to the same API the browser uses. Run `./bs.sh` with no arguments to see
everything it can do.

## 1. The catalog model, from the live catalog (10 min)

Everything in the catalog is an **entity**: a YAML document with `apiVersion`,
`kind`, `metadata` (name, description, annotations, tags) and `spec`. Its address is
`kind:namespace/name`, for example `component:default/demo-api`.

| Kind | It is... | Example here |
|---|---|---|
| **Component** | something that runs or is built: service, library, website | `demo-api`, `platform-lib` |
| **API** | a contract a component offers (OpenAPI, GraphQL, gRPC) | `demo-api` |
| **System** | components and APIs that together do one job | `demo-product`, `ci-platform` |
| **Domain** | a group of systems for one business area | `delivery` |
| **Resource** | infrastructure a component needs (database, cluster, bucket) | `eks-cluster` |
| **Group** / **User** | who owns things | `app-team`, `platform-team` |
| **Location** | a pointer to more files | the root `catalog-info.yaml` |
| **Template** | a recipe for creating new things (part 4) | `new-service` |

You never write the relations; you write **fields**, and Backstage derives **both
directions**: `spec.owner` creates `ownedBy` on the component and `ownerOf` on the
group; `spec.system` gives `partOf` / `hasPart`; `providesApis` gives `providesApi` /
`apiProvidedBy`; `dependsOn` gives `dependsOn` / `dependencyOf`. `lifecycle` is
`experimental`, `production` or `deprecated`, and **every entity has exactly one owner,
a team and not a person** (people leave; teams get paged).

Now read the live catalog and answer these out loud (the browser **and**
`./bs.sh get` both work; "Inspect entity" in the page's menu shows the raw data):

1. `demo-api`: who owns it, which system is it part of, what lifecycle, which API does it
   provide? (`./bs.sh get component demo-api`)
2. Open its page, then **APIs**: what do you see? Then the catalog graph at
   http://backstage.192.168.0.23.nip.io/catalog-graph (put `demo-api` as the root entity): which
   arrows are `ownerOf`, `partOf`, `providesApi`, `dependsOn`?
3. Which Groups exist, and which System does `platform-team` own? In the catalog
   table choose kind **Group** and **System**.
4. Where does all of this come from? (Answer: one line in the Backstage config,
   `catalog.locations`, points at `catalog-info.yaml` in the lab's GitHub repository.
   That file is a `Location` listing the files in `catalog/`. Backstage re-reads them
   regularly. Its database here is **in memory**, so a restart rebuilds the catalog from
   git: **git is the source of truth**, Backstage is only a view.)
5. Why is the owner a Group?

## 2. Onboard a new service (15 min)

You are the team that owns a new **orders service**. Describe it so the portal knows
about it: a System, an API, and the Component that provides the API, all owned by an
existing team.

**2a. Write the file.** Start from the starter and make it yours:

```bash
sed "s/candidate/$EX_PREFIX/g" starter-catalog-info.yaml > ~/orders-service/catalog-info.yaml
```

Open `~/orders-service/catalog-info.yaml` and fill in every `TODO` (owner, system,
lifecycle, `providesApis`, the source-location with your own GitHub user and repo). The
names you must end up with (the check looks for them):

* component `<prefix>-orders`, API `<prefix>-orders-api`, system `<prefix>-shop`

Before you push, ask Backstage whether the *shape* is valid (this does not need GitHub):

```bash
./bs.sh validate ~/orders-service/catalog-info.yaml
```

It cannot know if the owner or system you named **exist**; that comes later.

**2b. Push it.**

```bash
cd ~/orders-service && git add catalog-info.yaml && git commit -m "Add catalog entry" && git push; cd -
```

**2c. How a file reaches Backstage. Read this, it is the real lesson.**
Registering a URL means the Backstage *backend* (the pod in the cluster) must be
allowed to fetch it. I tried each option against this lab on 2026-10-17:

| URL you could register | Works? | What happens |
|---|---|---|
| `https://github.com/<user>/<repo>/blob/main/catalog-info.yaml` (public repo) | **Yes** | Backstage has a built-in GitHub integration for `github.com`. A file from another user's public repo went in and showed up in the catalog in about 5 seconds. **Use this.** |
| `https://raw.githubusercontent.com/...` | No | `Reading from '...' is not allowed. You may need to configure an integration for the target host, or add it to the configured list of allowed hosts at 'backend.reading.allow'` |
| a GitHub Gist | No | same message |
| the playground Gitea (`192.168.0.23:30300`) | No | same message |
| a private GitHub repository | No | no token is configured, so GitHub says not found |

The pattern: **Backstage reads only hosts it has an integration for or that are listed in
`backend.reading.allow`**. This is a safety feature (otherwise the portal could be made to
fetch any URL from inside your network: server-side request forgery). Prove it to yourself:

```bash
./bs.sh dry-run https://raw.githubusercontent.com/<your-user>/orders-service/main/catalog-info.yaml   # refused
./bs.sh dry-run https://github.com/<your-user>/orders-service/blob/main/catalog-info.yaml           # accepted
```

(`dry-run` is the same check the browser does before it lets you press Import. It
stores nothing.) Use your own user and repo names.

**2d. Register it, the way a developer would.** In the browser: **Create**, then
**Register Existing Component** (or go straight to
http://backstage.192.168.0.23.nip.io/catalog-import). Paste the `github.com/.../blob/main/catalog-info.yaml`
URL, **Analyze**, look at the entities it lists, **Import**.

The same thing from the terminal, if you prefer (the UI does exactly this: a dry run, then
a POST):

```bash
./bs.sh register https://github.com/<your-user>/orders-service/blob/main/catalog-info.yaml
```

**2e. Look at the result.** In the catalog, open `<prefix>-orders`. Check the **Overview**
(owner, system, lifecycle), the **APIs** tab (does it render your OpenAPI?), and the graph.
Then:

```bash
./bs.sh get component "$EX_PREFIX-orders"
```

Questions: which relations did you write, and which did Backstage add on its own? Open the
**System** page: is your component listed there? (That is `hasPart`, derived.) If a team
asks "who owns the orders service and what does it depend on?", where do you send them?

No repo you want to keep? A throwaway public one is the cheapest route: a file on your
disk or in a gist cannot be registered (see the table).

## 3. Find and fix a broken entity (15 min)

A colleague wrote `broken/catalog-broken.yaml` in a hurry. It has **five** problems: three
that Backstage rejects (it names only one per attempt) and two that it accepts silently. Your job is to find them using Backstage's own signals, then fix the file.
**Do not open `solution/` yet.**

Put it in your repository and push:

```bash
sed "s/candidate/$EX_PREFIX/g" broken/catalog-broken.yaml > ~/orders-service/catalog-broken.yaml
cd ~/orders-service && git add catalog-broken.yaml && git commit -m "Add ledger entry" && git push; cd -
```

**3a. Register it in the browser first** (part 2d with `.../blob/main/catalog-broken.yaml`).
The page runs the same dry run as `./bs.sh dry-run` first, so it should show you the
problem instead of importing. That is the safety net.

**3b. Now see what it looks like when there is no safety net.** Register with the API:

```bash
./bs.sh register https://github.com/<your-user>/orders-service/blob/main/catalog-broken.yaml
```

It says registered (HTTP 201) and **nothing appears in the catalog**. That is the trap:
an invalid entity is *dropped*, the location stays, and the browser shows no error
for it. Find out why, using these in turn:

```bash
./bs.sh dry-run https://github.com/<your-user>/orders-service/blob/main/catalog-broken.yaml
./bs.sh validate ~/orders-service/catalog-broken.yaml
export KUBECONFIG=$PWD/../../../homelab/generated/rke2-lan.kubeconfig   # once, for the next line
./bs.sh errors 30m
```

The last one reads the Backstage pod's log (Headlamp also shows it: namespace `backstage`).
That log is where the catalog writes `Policy check failed for component:default/...` and similar
lines; in this image there is no "unprocessed entities" page in the UI, so **the log is
where you look**. Say why that is a gap you would close (an alert, or the
unprocessed-entities plugin).

Backstage reports **one problem at a time**: fix, `./bs.sh validate` again, repeat until
it says valid. When the shape is valid, push, then make Backstage re-read now instead of
waiting about two minutes:

```bash
./bs.sh locations                       # find the "generated-..." ref of your broken file's location
./bs.sh refresh location:default/generated-<hash>
./bs.sh get component "$EX_PREFIX-ledger"
```

**3c. The two silent problems.** When `./bs.sh get component <prefix>-ledger` finally
works, read the output carefully, then look at the entity in the browser. Something is
off even though Backstage accepted it: one value is not one of the three the catalog
filters on, and one reference points at something that is not in the catalog (open the
**System** link on its page; or check the `partOf` line). Backstage never validates that a
*referenced* entity exists. The check script does.

Fix all five, push, refresh, then run the check in part 5.

## 4. How would you extend Backstage? (read and describe; do not build)

The lab's Backstage is the **stock image** (`ghcr.io/backstage/backstage`), configured
through `homelab/platform/values/backstage.yaml`. That decides what you can and cannot
do. Look at each item below and be ready to explain it.

* **Templates (the "scaffolder"; the golden path).** Open **Create**: there is one template,
  `New Python service on the golden path`. Read `templates/new-service/template.yaml` in this
  repo: a form (`parameters`, with an owner picker that lists real Groups) and `steps`
  (`fetch:template` renders the files from `skeleton/`, which includes a `catalog-info.yaml`;
  `publish:github` and `catalog:register` are commented out because this lab has no GitHub
  token). Why do platform teams build these? (A developer answers four questions and gets a
  repo with the pipeline, Dockerfile and catalog entry the platform team already decided on,
  instead of copying an old project.) Which step would put the new service into the
  catalog without anyone registering a URL? (`catalog:register`.)
  *State of this lab (2026-10-17): running the template fails at its first step. I ran it
  through the API and the task log says `Request failed for https://api.github.com/repos/.../commits/feat/status ... 404`;
  the cause was not investigated. If you want a debugging puzzle, open the failed task's log page
  in the browser after you run the template.*
* **TechDocs (docs as code).** Add `backstage.io/techdocs-ref: dir:.`, a `mkdocs.yml` and
  a `docs/index.md` to a repo, and the **Docs** tab renders it. In production a CI job
  builds the site and publishes it to object storage (S3/GCS), and Backstage only
  serves it. Here the Docs page is empty because no entity has the annotation.
* **Plugins.** A plugin has a frontend part (a tab, a card, a page) and a backend part
  (an API to a tool: Jenkins, Argo CD, PagerDuty, Artifactory). **This lab cannot add
  one:** the entity pages have only Overview, TechDocs, APIs and Kubernetes, and the
  `jenkins.io/job-full-name` annotation on `demo-api` does nothing because the Jenkins
  plugin is not in the image. To add plugins you build **your own image**:
  `npx @backstage/create-app`, `yarn add` the plugin packages, build the image in CI,
  push it to the registry, change the image tag in the chart values, and Argo CD rolls it
  out. Say that this is a real, ongoing cost: every Backstage upgrade touches every plugin.
* **Catalog providers.** Hand-registering URLs does not scale. A GitHub **entity provider**
  scans an organisation for `catalog-info.yaml` files and registers them all; Groups
  and Users come from GitHub teams or the identity provider. This lab hand-writes
  `catalog/org.yaml` instead.
* **What the lab switched off, and why.** Plain `http` means the browser has no secure
  context, so search, notifications and the permission framework are off (see the comments
  in `values/backstage.yaml`). With the permission framework off, every guest can register
  or delete locations. In production you would sign in with GitHub or OIDC and switch
  permissions on.

## 5. Check, say it out loud, clean up

```bash
./check.sh
```

It reads the catalog through Backstage's API (nothing is changed) and checks, per entity:
it exists; it came from a GitHub URL; no processing errors; the owner is a Group
**that exists**; the System **exists** and lists the component back; lifecycle is one of
the three; the API exists and has a definition. It does this for `<prefix>-orders` (part 2)
and `<prefix>-ledger` (part 3). Exit code 0 means every required check passed.

**Say it, two minutes each:**

* What is Backstage and what problem does it solve? (One place to find services, owners,
  APIs, docs and runbooks; fewer "who owns this?" pings; onboarding by template.)
* The catalog model and the relations, using `demo-api` as the example.
* How does an entity get in, and what are the failure modes? (Pushed to git and
  registered once or discovered; an invalid entity is dropped silently; a dangling reference
  is accepted; the source of truth is git, so a stale file means a stale catalog.)
* How would you extend it, and what would it cost? (Part 4.)
* What would worry you about running it in production? (The in-memory database here loses
  scaffolder history on restart; plugin upgrades; the catalog drifting from reality;
  ownership data that nobody keeps up to date.)

**Clean up** (so the lab's catalog is back to what it was):

```bash
./bs.sh locations                 # your registered files, with ids
./bs.sh unregister <id-or-url>    # once per location (orders and broken)
```

Their entities leave the catalog within seconds. Delete the GitHub repository if you
like. If you forget, nothing breaks: just run `./check.sh` with another prefix later, or
unregister then.

## Files in this folder

| File | What it is |
|---|---|
| `bs.sh` | Catalog client: `validate`, `dry-run`, `register`, `locations`, `refresh`, `unregister`, `get`, `errors` |
| `starter-catalog-info.yaml` | Part 2: the file to fill in |
| `broken/catalog-broken.yaml` | Part 3: the broken entity |
| `solution/` | Answers for parts 2 and 3. Look only after you tried |
| `check.sh` | Read-only check of your work (tick or cross per step) |
| `lib.sh` | Shared helpers (guest sign-in), used by the scripts |

Scripts use only `bash`, `curl` and `python3` (plus `kubectl` for `bs.sh errors`, and PyYAML or
macOS's built-in Ruby for `bs.sh validate`). They run on macOS and Linux.

---

Verified 2026-10-17 against the live lab (Backstage 1.55.2, plain http). What was run, and what was
not. **Ingestion path, end to end:** `./bs.sh dry-run`, `register`, `get`, `locations` and `unregister`
with a real component from a public GitHub repo that is not ours
(`backstage/backstage`, `artist-lookup-component.yaml`): in the catalog about 5 seconds after
registering, with `ownedBy`/`partOf`/`dependsOn` relations, gone after unregistering; the catalog
went back to 22 entities. `raw.githubusercontent.com`, a gist and a Gitea URL were each refused with
the `backend.reading.allow` message. **A real broken entity:** registering the template
skeleton `catalog-info.yaml` from this repo (`${{ values.name }}` is not a valid name) answered 201
with no entity, and `./bs.sh errors` showed the `Policy check failed` line from the pod log.
**The exercise files:** the filled-in starter, `solution/` files and `broken/` file were run through
Backstage's validator (`./bs.sh validate`): the solutions are valid, the broken one fails in the
order tags, apiVersion, owner. **`check.sh`:** passed 20 of 20 pointed at lab entities
(`EX_COMPONENT=demo-api EX_API=demo-api EX_BROKEN=platform-lib`) and fails with hints on missing or
dangling references (tested with `artist-lookup`, whose owner and system are not in the catalog).
**Not run:** pushing your own repo and registering your own files (no push was allowed while building this),
so parts 2d and 3 on your own URL, and the browser clicks of the Register page, are verified only through the
same API calls the page makes. Running the Create template fails in this lab (see part 4).
