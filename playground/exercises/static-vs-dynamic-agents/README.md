# Exercise: static vs dynamic agents, side by side (about 45 minutes)

Not a scored drill: nothing breaks and there is no clock. You run the **same
pipeline** on a permanent agent and on a Kubernetes pod, **measure** what is
different, and afterwards you can answer the interview question *"static vs
dynamic agents: what are the trade-offs, and how does each one break?"* with
things you have seen yourself. Three scored drills build on this
(51, 52, 53); do the exercise first.

Everything so far in the playground ran on **dynamic** agents: a pod made from
a template for one build and deleted after it (the Kubernetes plugin). This
adds a **static** one: `static-01`, a long-lived Linux box (a Docker container,
`pg-static-01`, 512 MB) that connects to the controller by itself and stays.

| | Static (`static-01`) | Dynamic (pod) |
|---|---|---|
| What it is | a machine that exists before and after the build | a pod created for this build, deleted after |
| Picked by | `agent { label 'static' }` | `agent { kubernetes { yaml '...' } }` |
| Where it lives | outside the cluster, its own disk and lifetime | inside the cluster, the pod's disk |
| Who keeps it healthy | you (secret, disk, patches, tools) | the cluster and the pod template |

| Step | What you do | Minutes |
|---|---|---|
| 0 | Set up and look at both kinds of agent | 5 |
| 1 | The same pipeline, one different line | 3 |
| 2 | Workspace persistence | 8 |
| 3 | Executors and queueing | 7 |
| 4 | Cold start, measured | 5 |
| 5 | What "offline" looks like for each | 8 |
| 6 | Security: what a static agent leaves behind | 5 |
| 7 | `./check.sh`, notes, interview questions | 5+ |

You need the playground running on this computer (`playground/play doctor`
green) and Docker with about 1 GB to spare (the static agent takes 512 MB; on a
4 GB Docker VM do not run anything else heavy). **Never run two *dynamic*
builds at once on a small Docker VM.** Starting two *static* builds at once is
part of step 3 and costs nothing.

---

## 0. Set up and look around

```bash
cd playground/exercises/static-vs-dynamic-agents
./lab.sh seed          # brings static-01 up (setup/static-agent.sh up) and creates 3 jobs
./lab.sh status
```

Open http://localhost:30094 (login `admin`, password in
`~/.local/state/platform-lab-playground/creds.env`).

1. **Manage Jenkins > Nodes.** You see *Built-In Node* and *static-01*. Built-in:
   0 executors, on purpose (the controller holds every credential and runs no
   builds). Open **static-01 > Configure**: the label `static linux`, 1 executor,
   usage "Only build jobs with label expressions matching this node", launch
   method "Launch agent by connecting it to the controller" with **Use WebSocket**.
2. **Manage Jenkins > Clouds > kubernetes.** Pods are *not* nodes you register:
   the cloud creates them on demand, up to a concurrency limit.
3. On the machine: `docker ps --filter name=pg-static`, and
   `playground/setup/static-agent.sh status` (note "workspace disk": a small,
   bounded volume; drill 53 is about that).

**Say out loud:** why would a team keep a permanent agent at all when pods exist?
(Licensed software tied to a host, a hardware token or HSM, a VPN route, a
very large cache, a GPU, an OS Kubernetes does not run.)

## 1. The same pipeline, one different line

Open **sva-static** and **sva-dynamic > Configure** side by side (the sources
are in `pipelines/`). Everything is identical except the first line:

```groovy
agent { label 'static' }                    // sva-static: wait for a node with this label
agent { kubernetes { yaml '...' } }         // sva-dynamic: create a pod from this template, then run in it
```

The steps print the node name, the user, a **marker** file left by the previous
build, a fake deploy token, the disk, and the **cold start** (time from build
start to the first step on the agent).

## 2. Workspace persistence

Run **sva-static** twice (Build Now, wait for it to finish, Build Now again).
Open the second console:

```text
Running on static-01 in /home/jenkins/agent/workspace/sva-static
MARKER=found (left by build 1 of sva-static at 17:27:35)
```

Now run **sva-dynamic** twice:

```text
Running on sva-dynamic-2-7fs1m-1v69q-wkfz4 in /home/jenkins/agent/workspace/sva-dynamic
MARKER=absent
```

Same path, same job, same steps. On the pod the workspace did not exist before
the build and is gone after it. Also look at the machine:
`docker exec pg-static-01 ls -la /home/jenkins/agent/workspace/sva-static`.

**Answer in your notes:** (a) what is the upside of a persistent workspace
(incremental builds, a warm cache, no re-clone), (b) the downside (the second build
depends on the first: stale files, a poisoned cache, "works the first time"; that
is drill 52), (c) how you get the upside on pods anyway (a keyed cache, a
persistent volume, a build cache in the registry or Artifactory).

## 3. Executors and queueing

`static-01` has **1 executor**. Start `sva-static` twice quickly (Build Now,
Build Now). Open the second build's page and the queue (the left menu of the
Jenkins front page, "Build Queue"):

```text
Waiting for next available executor on 'static-01'
```

It runs when the first finishes (the job holds the executor 20 s on purpose).
Capacity of a static agent is **fixed**: executors x machines. More work than that
queues, however empty the cluster is. Pods are different: each build asks for its
own pod, so the limit is what the cluster can schedule plus the cloud's
**Concurrency limit** (Manage Jenkins > Clouds > kubernetes). Drills 05 and 43
are what happens when *that* limit or the scheduler says no.

**Answer:** what do you do when the static queue is always long? (More
executors, if the box has the CPU and the builds do not collide on ports/files; a
second static agent with the same label, which Jenkins load-balances; or move
the jobs that do not need the box to pods.) Why is "more executors" risky on a
static agent? (Builds share the machine and the disk; two builds of the same job
get `workspace@2`.)

## 4. Cold start, measured

Run each job **three** times. Read `COLD_START_MS=` from the console, write the
numbers down:

| | run 1 | run 2 | run 3 |
|---|---|---|---|
| static | | | |
| dynamic | | | |

Typical here: static a few hundred ms (the agent is already connected, only a
lock and a message), dynamic 2-3 s with the image already on the node. The
**first** pod after a new image tag is much slower (image pull; the large images
in the real library template, BuildKit and `alpine/k8s`, took minutes on first
pull). Say why the numbers move: image cached or not, node has room or the
cluster has to scale, the pod's `jnlp` sidecar start-up.

**Answer:** when does a 2-second start-up not matter, and when does it? (A
15-minute build: never. A 20-second lint job run 200 times a day: it is the
build.) What would you do about pod start-up? (Smaller or pre-pulled images,
a warm pool, fewer containers per pod.)

## 5. What "offline" looks like for each

**Static.** Take the box away and run a build:

```bash
docker stop pg-static-01
# Build Now on sva-static, then open Manage Jenkins > Nodes and the Build Queue
```

The node says `Connection was broken`; the build waits with
`'static-01' is offline`. Nothing is red, nothing is failing: it is **waiting
for a specific machine**, forever. Bring it back:

```bash
docker start pg-static-01       # it reconnects by itself; the waiting build starts
```

**Dynamic.** Break the template instead, not the cluster. In **sva-dynamic >
Configure** change the image to `python:3.13.99-slim` (a tag that does not
exist), Build Now, open the console:

```text
Container [tools] waiting [ErrImagePull] ... failed to resolve reference "docker.io/library/python:3.13.99-slim"
Pod [Pending][ContainersNotReady] containers with unready status: [tools]
```

and `kubectl --context kind-playground -n jenkins get pods` shows
`ImagePullBackOff`. Jenkins keeps retrying until the connect timeout, then the
build fails. Abort it, **change the image back**, and delete the leftover pod
(an aborted build's Pending pod is not reaped straight away: drill 05).

Note the difference in **where you look**: static, the reason is on the node
page and on the machine (`docker logs pg-static-01`, the controller log);
dynamic, it is the pod (`kubectl describe pod`, events). A static agent can be
offline for many reasons (network, a stale secret, a flag someone set, a full
disk) and drill 51 and 53 are two of them.

## 6. Security: what a static agent leaves behind

Run **sva-snoop** after sva-static has run. It is "another team's job" that
just lists the box it landed on:

```text
I am jenkins on build-01; other workspaces on this box:
...
found ../sva-static/.deploy-token:
FAKE-DEPLOY-TOKEN-2-not-a-real-secret
```

On a static agent, every job with that label runs as the **same user on the same
disk**, and what a build writes (workspace files, a `.netrc`, a kubeconfig, a
cached credential, `~/.docker/config.json`) is still there when the next one,
maybe a different team's, starts. On a pod the workspace and anything in the
user's home die with the pod, and the pod runs with its own service account.

**Answer:** what do you do if static agents are needed? (Wipe workspaces
at the end of the build and at the start of the next one; no credentials left
in files, use `withCredentials` so they are masked and temporary; one agent
per trust level, never a shared box for a team that handles production
secrets and a team that runs untrusted PR builds; patch and rebuild the box
from code on a schedule; a build user that is not root and cannot read other
workspaces.)

## 7. Check, notes, say it out loud

```bash
./check.sh
```

It reads Jenkins' own records: 2+ green runs of `sva-static` on `static-01`, one
that found the leftover file; 2+ green runs of `sva-dynamic` on pods that found
nothing; `sva-snoop` read the token; and it prints the cold-start numbers you
produced. Optional: write your answers to the **Answer** prompts in
`~/platform-playground/journal/static-vs-dynamic.md` (the check counts words).

Clean up when done (frees about 600 MB of Docker memory):

```bash
./lab.sh clean --agent
```

---

## Interview questions, with a model answer

**"Static vs dynamic agents: trade-offs?"**
> "Dynamic agents, pods in our case, give you a clean, identical environment for
> every build, capacity that scales with the cluster, no machine to patch, and
> nothing left behind, which is also the security story. The cost is cold start
> and no warm caches. Static agents are fast, keep caches, and are the only
> option when the work is tied to a host: a license, an HSM or signing key, a VPN
> route, special hardware. The cost is that they are pets: fixed capacity,
> workspace state leaking between builds, credentials left on disk, and you own
> their patching, disk and secret. My default is dynamic, and a static agent has
> to justify itself with one of those host-bound reasons, labelled so only the
> jobs that need it can land there."

**"How does each break?"**
> "A static agent breaks as a machine: it goes offline (a stale secret, a flag, the
> network, a changed host key or Java version), its disk fills because nothing
> cleans workspaces, or a build passes or fails depending on what the previous
> one left. The tell is that jobs *wait for that node* and nothing is red.
> Dynamic breaks as scheduling: the pod can't be placed (requests too big,
> quota), can't pull its image, or the cloud's concurrency limit is used up by
> builds that are idle, for instance waiting for an approval inside an agent. The
> tell is a Pending pod and events."

**"A job is stuck 'waiting for next available executor'. What do you check?"**
> "Whether it's a static label or a pod template. Static: the node page and the
> queue reason: offline, busy, wrong label, or flagged offline. Dynamic: pod
> status and events, the cloud's cap, who's holding the pods. Either way the queue
> reason in Jenkins is the first thing to read, then the machine or the pod."

**"How do you keep a static agent healthy?"**
> "Build it from code so it can be recreated, not repaired; wipe the workspace
> at the start and end of each build; build discarders and a scheduled sweep;
> alert on offline-longer-than-N and on disk free before the monitor's own
> threshold; never lower the monitor to make it go away; keep its secret out of
> stale copies; patch on a schedule; one agent per trust level."

**"Would you move everything to pods?"**
> "No: the host-bound jobs stay on a labelled static agent, but they're
> the exception, they have an owner, and the pipeline starts from a clean
> workspace so it behaves like a pod would. Everything else moves, starting
> with whatever has the most queue time."

Drills that use this setup: **51** (a static node offline for two reasons, only
one of them visible), **52** (a build that passes or fails on what the last
one left), **53** (the workspace disk fills and Jenkins takes the node
offline). Dynamic-side companions: **05** (pods Pending) and **43** (idle
builds holding the pod cap).
