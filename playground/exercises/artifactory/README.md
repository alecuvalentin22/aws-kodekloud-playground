# Exercise: Artifactory, built by hand (45 to 60 minutes)

Not a scored drill: nothing breaks and there is no clock. You **build** a small
artifact setup in the lab's Artifactory, use it from a real Maven client, and
afterwards you can say "I have done this" about the job description line
*"Support Artifactory for artifact and dependency management"*.

You already know Harbor (a registry for container images) and a Maven registry.
Artifactory is the same idea for **every** kind of binary, and it adds one thing
Harbor does not do: it sits **between your builds and the internet** as a cache.

| Step | What you do | Minutes |
|---|---|---|
| 0 | Set up, look around | 5 |
| 1 | Create a local, a remote and a virtual repository | 10 |
| 2 | Fetch one file through the virtual repo, see it cached | 5 |
| 3 | Resolve a real dependency with a Maven client | 10 (the first run is slow, see below) |
| 4 | Upload your own artifact with a checksum, download it back | 10 |
| 5 | `./check.sh` | 2 |
| 6 | Optional: point Jenkins at it (read and describe) | 5 |
| 7 | Say it out loud, clean up | 10 |

You need: the Mac terminal in this repo, the home Wi-Fi, **Docker running** (step 3),
and the shared lab password (never written in the repo).

---

## 0. Set up and look around

```bash
cd playground/exercises/artifactory
export EX_PREFIX=candidate        # the name of everything you create. New prefix = fresh start.
read -r -s HOMELAB_ADMIN_PASSWORD; export HOMELAB_ADMIN_PASSWORD   # type the shared password; nothing is shown
```

`EX_PREFIX` may only use lower-case letters, digits and `-`. The helper scripts
read the password from that variable and never put it on a command line (a
command line can be seen by anyone on the machine with `ps`).

Open http://artifactory.192.168.0.23.nip.io in the browser and log in as `admin`.
Click around: **Application > Artifactory > Artifacts** is the tree of repositories
and the files in them; **Administration > Repositories** is where they are managed.

Now the same from the terminal (`art.sh` adds the login for you):

```bash
./art.sh GET /api/system/version      # look for "license": "Artifactory OSS"
./art.sh GET /api/repositories        # key, type (LOCAL / REMOTE / VIRTUAL), package type
```

**Question to answer out loud:** which repositories exist already, and which of
them could you use for Maven? (There is a shared `maven-remote`, and some generic
and Docker-looking entries left from earlier tests. Do not touch them.)

## 1. Create the three repositories

Three kinds, one job each. Create them in this order, because the virtual one
needs the other two to exist.

> **Why a script and not `PUT /api/repositories/...`?** That REST call is
> **Pro-only**; OSS answers *"This REST API is available only in Artifactory Pro"*.
> The web UI uses a different, internal call, and OSS accepts it from a logged-in
> UI session. `art.sh create-repo` makes exactly that call: it is what the
> "Create Repository" button does. In Pro you would use the REST API, the JFrog
> CLI, or Terraform.

**1a. Local repository: where your own artifacts live.**

```bash
./art.sh create-repo local "$EX_PREFIX-maven-local"
```

**1b. Remote repository: a caching proxy of Maven Central.**

```bash
./art.sh create-repo remote "$EX_PREFIX-maven-remote" https://repo1.maven.org/maven2
```

**1c. Virtual repository: one address that combines the other two.**
Arguments: name, the repositories it contains (order matters, see below), and
the repository that receives uploads.

```bash
./art.sh create-repo virtual "$EX_PREFIX-maven-virtual" \
  "$EX_PREFIX-maven-local,$EX_PREFIX-maven-remote" "$EX_PREFIX-maven-local"
```

Each call answers `Successfully added repository ...` (HTTP 200). Running one
again answers "already exists", which is harmless.

Refresh **Administration > Repositories** in the browser and find your three.
Then open the **Artifacts** tree and notice `<prefix>-maven-remote-cache`: a remote
repository is really **two** things, the *configuration* (where to fetch from) and
a *cache* (what was fetched). It is empty now.

**Say it in your own words (this is the interview question):**

* **Local**: you own it, you upload to it. Your company's own libraries and
  release builds. Nothing outside ever writes to it.
* **Remote**: a proxy plus cache for someone else's repository (Maven Central, npm,
  Docker Hub). The first request goes out to the internet; the answer is stored; every
  later request is served from the cache.
* **Virtual**: no storage of its own. It is a *view* over several repositories
  behind one URL. Developers and CI use **only** this URL; you can later add a second
  remote, move a repository, or swap Maven Central for a mirror **without changing
  one client**. Resolution tries the members in order (your local first, so a
  company's own artifact always wins over a same-named one from outside, which is
  also the defence against dependency-confusion attacks). Uploads go to its default
  deployment repository.

## 2. Fetch one file through the virtual repository

```bash
./art.sh GET "/$EX_PREFIX-maven-virtual/junit/junit/4.13.2/junit-4.13.2.pom" | head -5
```

You asked your *virtual* repo; it asked its members; the remote one went to
Maven Central, stored the answer, and handed it back. Prove it was stored:

```bash
./art.sh GET "/api/storage/$EX_PREFIX-maven-remote-cache/junit/junit/4.13.2/junit-4.13.2.pom"
```

Read this answer carefully:

* `remoteUrl`: where it came from.
* `checksums`: sha1, md5 and sha256 that **Artifactory computed** over the stored bytes.
* `originalChecksums`: what the **source** (or the uploader) claimed. For a remote file
  they should match; if they did not, Artifactory's checksum policy would reject it.
* In the browser: the file now sits under `<prefix>-maven-remote-cache`.

Permissions, quickly. Ask for the same file **without** logging in:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  "http://artifactory.192.168.0.23.nip.io/artifactory/$EX_PREFIX-maven-virtual/junit/junit/4.13.2/junit-4.13.2.pom"
```

`401`: anonymous access is off. Nobody reads or writes anything without an
identity. (The password is not in that command: there is none.)

## 3. Resolve a real dependency from a Maven client

A throwaway container plays "a developer's laptop or CI agent that has never seen
this dependency". `settings.xml` in this folder tells Maven: *"for every repository you
would normally contact, use this one address instead"* (a mirror of `*`), and it
takes the credentials from environment variables, so no secret is in the file.

```bash
docker run --rm \
  -e HOMELAB_ADMIN_PASSWORD -e EX_PREFIX \
  -e ART_USER=admin -e ART_URL=http://artifactory.192.168.0.23.nip.io \
  -v "$PWD/settings.xml:/root/.m2/settings.xml:ro" \
  maven:3.9-eclipse-temurin-17 \
  mvn -B org.apache.maven.plugins:maven-dependency-plugin:3.6.1:get \
      -Dartifact=org.apache.commons:commons-lang3:3.14.0
```

(`-e HOMELAB_ADMIN_PASSWORD` with no `=value` passes your shell's value into the
container without writing it in the command.)

**Be patient: the first run takes 2 to 4 minutes** (measured 3m27s and 2m27s on 2026-10-17,
plus the one-time download of the Maven image). Maven first has to fetch its own
*plugin* and the plugin's dependencies, about 320 small files, and **every one of them
goes through your virtual repository**. Read the output: each line says
`Downloading from artifactory: http://.../<prefix>-maven-virtual/...`. Nothing went to
the internet directly. That is the point of a mirror.

**Now run the exact same command again.** It is a brand-new container with an empty
`~/.m2`, so Maven asks for all 320 files again, but now Artifactory answers from its
cache: about 40 seconds (measured 38s). Same client, same files, no trip to Maven
Central. That is what a proxy cache buys a CI system with fifty agents.

See what was cached (AQL, Artifactory's query language, works on OSS):

```bash
./art.sh POST /api/search/aql -H 'Content-Type: text/plain' \
  --data-binary "items.find({\"repo\":\"$EX_PREFIX-maven-remote-cache\",\"name\":{\"\$match\":\"commons-lang3*\"}})"
```

And compare Artifactory's checksum with the one Maven Central publishes:

```bash
./art.sh GET "/api/storage/$EX_PREFIX-maven-remote-cache/org/apache/commons/commons-lang3/3.14.0/commons-lang3-3.14.0.jar" | grep sha1
curl -s https://repo1.maven.org/maven2/org/apache/commons/commons-lang3/3.14.0/commons-lang3-3.14.0.jar.sha1; echo
```

Both are `1ed471194b02f2c6cb734a0cd6f6f107c673afae`. Say why a company cares:
**integrity** (the file is the one the publisher released), **availability** (Maven
Central down, or a library deleted upstream, and your builds still work),
**speed and cost** (one download instead of fifty), and **control** (one place to scan
or block things).

## 4. Upload your own artifact with a checksum, download it back

Make a tiny "library" (a jar is a zip file) and compute its checksums *on your side*:

```bash
mkdir -p work && cd work
printf 'hello from %s\n' "$EX_PREFIX" > greeting.txt
zip -q hello-1.0.0.jar greeting.txt
SHA1=$(shasum -a 1 hello-1.0.0.jar | cut -d' ' -f1)
SHA256=$(shasum -a 256 hello-1.0.0.jar | cut -d' ' -f1)
echo "$SHA1  $SHA256"
```

Maven layout means the path is `groupId/artifactId/version/artifactId-version.jar`.
Use the group `com.example.<prefix>`, artifact `hello`, version `1.0.0`:

```bash
DEST="/$EX_PREFIX-maven-local/com/example/$EX_PREFIX/hello/1.0.0/hello-1.0.0.jar"
```

**First send a wrong checksum on purpose:**

```bash
../art.sh PUT "$DEST" -T hello-1.0.0.jar \
  -H "X-Checksum-Sha1: 0000000000000000000000000000000000000000"
```

`409 ... rejected the artifact`: Artifactory computed its own sha1 over what arrived,
saw it differed from what you *said* you sent, and refused. This is how a corrupted
upload (or a tampered one) is caught on the server.

**Now the real upload:**

```bash
../art.sh PUT "$DEST" -T hello-1.0.0.jar \
  -H "X-Checksum-Sha1: $SHA1" -H "X-Checksum-Sha256: $SHA256"
```

`201`, and the reply lists `checksums` and `originalChecksums` (the one **you** sent),
equal. Download it back **through the virtual repository** (a consumer never uses
the local repo's address) and prove the bytes are identical:

```bash
../art.sh GET "${DEST/$EX_PREFIX-maven-local/$EX_PREFIX-maven-virtual}" > back.jar
shasum -a 256 hello-1.0.0.jar back.jar        # two identical lines
cd ..
```

Finally consume it exactly like any dependency (Maven warns that the POM is missing;
expected, you uploaded a bare jar):

```bash
docker run --rm -e HOMELAB_ADMIN_PASSWORD -e EX_PREFIX \
  -e ART_USER=admin -e ART_URL=http://artifactory.192.168.0.23.nip.io \
  -v "$PWD/settings.xml:/root/.m2/settings.xml:ro" \
  maven:3.9-eclipse-temurin-17 \
  mvn -B org.apache.maven.plugins:maven-dependency-plugin:3.6.1:get \
      -Dartifact="com.example.${EX_PREFIX}:hello:1.0.0"
```

**Say it:** why checksums matter on upload (integrity, and the server stores files
**by their checksum**, so identical bytes are stored once however many repositories
list them); and that a release version is **immutable**: you never overwrite
`1.0.0`, you publish `1.0.1`.

## 5. Check your work

```bash
./check.sh
```

It reads Artifactory's API (nothing is changed) and prints a tick or a cross for
each step: the three repositories exist with the right types, Maven Central is the
upstream, a jar sits in the cache with matching checksums and is visible through the
virtual repo, and your own jar is in the local repo with a client-sent checksum and has
been downloaded back. Exit code 0 means every required step passed.

## 6. Optional: point Jenkins at it (read and describe)

You do not have to build this; be ready to describe it. The platform Jenkins
already has a working example from the lab: credential `artifactory-admin` and the job
`artifactory-publish-test` (script:
`homelab/platform/fixtures/artifactory-publish-test.Jenkinsfile`). Open
http://jenkins.192.168.0.23.nip.io, run it, and compare the file it uploads to
`generic-local/jenkins/<n>.txt` in the Artifactory tree.

Questions to answer from that script:

1. Which address does it use, and why not the `nip.io` one? (Inside the cluster:
   the Service `artifactory.artifactory.svc.cluster.local:8082`. A pod does not need the
   front door, and it works when the Wi-Fi name changes.)
2. How does the password reach `curl` without being printed? (`withCredentials`;
   Jenkins masks it in the log as `****`.)
3. How would you make a **Maven** build use your virtual repo? (A `settings.xml` with
   the mirror from this folder, mounted into the build pod from a Jenkins config file or a
   Secret; `<distributionManagement>` or `mvn deploy -DaltDeploymentRepository` for
   publishing.)
4. What would you put in place before ten teams use it? (A service account per team,
   not `admin`; tokens instead of passwords; permission targets, see below.)

## 7. Say it out loud

Two minutes each, to an imaginary interviewer:

* **What is Artifactory, and why a proxy cache?** (Section 3. Integrity, availability,
  speed, control; plus: build reproducibility, and one audit point for what enters your
  company.)
* **Local vs remote vs virtual.** (Section 1.)
* **Checksums.** sha1/sha256/md5 computed by the server, verified against what the client
  or upstream claimed, files stored by checksum, `.sha1` files next to every artifact in
  Maven; and pinning a hash in a build is how you notice tampering.
* **Permissions.** In Artifactory a *permission target* says: this set of repositories
  (and path patterns) can be **read / annotated / deployed to / deleted from / managed**
  by these users or groups. Least privilege looks like: CI can *deploy* to the release
  local repo and only *read* the virtual one; developers can read; only a few people can
  delete; nobody uses `admin`; anonymous is off (you saw the `401`). Use access tokens,
  not passwords, in pipelines.

### What this edition cannot do, and what you would use instead

Honest limits are a good interview answer. "Tried" means I ran it against this lab.

| Not on OSS | Evidence | What you would use |
|---|---|---|
| Docker / OCI registry | UI accepts the entry, but `/v2` answers 404 (tried 2026-10-16) | **Harbor** (you know it), ECR, plain `registry:3` (this lab uses it), JFrog Container Registry, or Artifactory Pro |
| PyPI, npm, and most other package types | repository created, but the PyPI index route is 404 and `pip` finds no versions (tried) | Artifactory Pro, or a dedicated tool such as Nexus or devpi/Verdaccio |
| Managing repositories over REST (`PUT/DELETE /api/repositories`) and reading a repository's configuration | *"available only in Artifactory Pro"* (tried) | Pro, then **Terraform** (the `artifactory` provider) or the JFrog CLI, so repositories are code in git |
| **Deleting a repository** | REST: Pro-only (tried). The UI Delete is Pro-only too (tried 2026-10-16, see `homelab/platform/README.md`) | Pro. On OSS you empty them and leave them (see Clean up) |
| Users, groups and permission targets over REST | *"available only in Artifactory Pro"* (tried) | Pro, plus SSO (SAML/OIDC); the free edition is effectively one admin identity |
| Search by checksum, deep listing (`?list&deep=1`) | Pro-only (tried); AQL still works | Pro, or AQL |
| High availability, replication, federated repos | not offered on OSS (documented, not tried) | Artifactory Pro / Enterprise |
| Vulnerability scanning of what you store | not part of OSS (documented, not tried) | **Xray**, or Trivy/Grype in the pipeline |
| Build info and promotion (dev to staging to prod repo) | not part of OSS (documented, not tried) | Pro with the JFrog CLI or Jenkins plugin, or copy between repos from the pipeline |

And the limit that decides most real projects: **the free edition is for Maven-style
Java ecosystems and generic files**. A platform that must host Docker images, Helm
charts, npm and PyPI needs Pro/Enterprise or a different product.

## Clean up

```bash
./cleanup.sh        # deletes your uploaded jar and empties your remote cache
rm -rf work
```

The repositories themselves **cannot be deleted on OSS** (no REST call, and the
UI's Delete is a Pro feature too). Empty repositories cost nothing, and if you run
the exercise again with the **same** `EX_PREFIX` they are simply reused (the
"already exists" answers are fine). A different prefix creates a new set that
stays forever, so prefer to keep one.

Leftovers from earlier lab tests that you can ignore: `docker-probe`,
`example-repo-local`, `generic-local`, `docker-remote`, `maven-remote`, `npm-remote`,
`pypi-remote`.

## Files in this folder

| File | What it is |
|---|---|
| `art.sh` | Tiny client: `./art.sh GET /api/repositories`, `./art.sh create-repo ...` |
| `settings.xml` | Maven settings: mirror everything to your virtual repo, credentials from the environment |
| `check.sh` | Read-only check of your work (tick or cross per step) |
| `cleanup.sh` | Deletes your uploaded jar and your cache contents |
| `lib.sh` | Shared helpers (password handling), used by the scripts |

Everything also works from Linux. The scripts use only `bash`, `curl`, `python3` and `zip`.

---

Verified 2026-10-17 against the live lab (Artifactory OSS 7.161.26) with `EX_PREFIX=verify`:
all of steps 0 to 5 run end to end, the commands copied from this file and run in `zsh` (the Mac
default; `$EX_PREFIX:hello` had to become `${EX_PREFIX}:hello` there) and the scripts in macOS's bash 3.2 (repositories created with `art.sh create-repo`;
`mvn dependency:get` of commons-lang3 3.14.0 in a throwaway `maven:3.9-eclipse-temurin-17`
container, 3m27s and 2m27s cold, 38s warm, 319 files through the virtual repo; wrong-checksum upload
answered 409, correct upload 201, sha256 identical after download through the virtual repo;
the uploaded jar resolved by Maven too); `./check.sh` passed 14 of 14 (and failed 5 of 7 for
a prefix with nothing built); `./cleanup.sh` emptied the verify repos and is idempotent.
Step 6 was read, not run. The three `verify-maven-*` repositories remain (OSS cannot delete them).
