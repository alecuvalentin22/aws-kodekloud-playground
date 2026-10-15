# Drill 18 — Pipeline to cluster: reading a failure from the right end

**The question:** "A deploy failed. Walk me through how you find out why."

Every failure below happened on the live lab (Jenkins on EKS, shared library in
`ci/shared-library/`, demo app in `ci/apps/demo-api/`). The error text is copied
from the console or `kubectl`, account IDs replaced with `<acct>`. None of it is
invented — where a scenario was not run, it says so.

The habit all of them teach: **find the first thing that went red, then ask
which layer produced the message.** The last line of a Jenkins console is almost
always `script returned exit code 1`, which says nothing.

---

## 1. Push fails with 401 — but IAM is fine

```
WARNING: Error loading config file: open /home/jenkins/agent/workspace/demo-api_main/.docker-1/config.json: permission denied
...
#11 ERROR: failed to push <acct>.dkr.ecr.us-east-1.amazonaws.com/platform-lab/demo-api:main-fa2626d4-1:
    unexpected status from HEAD request to https://<acct>.dkr.ecr.../blobs/sha256:...: 401 Unauthorized
```

**What actually happened.** The ECR login was written by the `deploy` container,
which runs as **root**, with mode 600. BuildKit runs **rootless as uid 1000** and
could not read it. BuildKit does not fail on an unreadable config — it prints a
WARNING, carries on anonymously, builds for a minute, and *then* the registry
says 401.

**How to read it.** 401 = *no credentials arrived*. 403/`denied` = *credentials
arrived and were refused* (see #2). Those point at completely different fixes.
The real cause was 140 lines above the error.

**Fix.** `chown 1000:1000` on the config directory (`vars/buildImage.groovy`).

## 1b. The same build leaked the ECR token into the console

Jenkins runs every `sh` step with `-x`, which prints each command **with its
variables expanded**:

```
+ TOKEN=eyJwYXlsb2FkIjoi...        <- the full registry token, in the build log
```

Anyone with read access to the job could copy it and push to the registry for
12 hours. `withCredentials()` masks secrets *it* binds; a token minted inside
the script is not bound, so nothing masks it.

**Fix.** `set +x` as the first line of any `sh` that handles a secret. The
build record was deleted. **Say this in an interview** — "I check what `-x`
prints before I trust a pipeline with a secret" is a mid-level answer most
candidates do not give.

## 2. Push fails with `denied` — IAM really is the problem

Reproduced by detaching `AmazonEC2ContainerRegistryPowerUser` from the node role:

```
ECR login written for <acct>.dkr.ecr.us-east-1.amazonaws.com (token not shown)
#11 ERROR: failed to push ...: denied: User: arn:aws:sts::<acct>:assumed-role/eksWorkerNodeRole/i-08c1...
    is not authorized to perform: ecr:InitiateLayerUpload on resource: arn:aws:ecr:us-east-1:<acct>:repository/platform-lab/demo-api
```

Note the **login succeeded**. `ecr:GetAuthorizationToken` is in the read-only
policy too (nodes need it to pull), so "I can log in" proves nothing about push.
The message names the principal (`eksWorkerNodeRole`), the action and the
resource — read all three.

**Production answer:** the node role should not push at all. Every pod on that
node inherits it. IRSA or EKS Pod Identity gives push to the agent's service
account only.

## 3. The agent cannot deploy outside its namespace

The agent service account has a Role in `demo-ci` only:

```
$ kubectl auth can-i <verb> <resource> --as system:serviceaccount:jenkins:jenkins-agent
create deployments -n demo-ci        yes
create deployments -n default        no
delete namespaces                    no
get secrets -n jenkins               no
patch deployments -n kube-system     no

error: failed to create deployment: deployments.apps is forbidden: User
"system:serviceaccount:jenkins:jenkins-agent" cannot create resource
"deployments" in API group "apps" in the namespace "default"
```

`kubectl auth can-i --as` is the fastest RBAC debugger there is: it answers
the question without running the pipeline. Note `get secrets -n jenkins: no` —
the agent cannot read the controller's own admin password.

## 4. New version never becomes Ready — and nobody notices

`FAIL_HEALTH=true` makes `/healthz` return 500:

```
$ kubectl -n demo-ci rollout status deploy/demo-api --timeout=60s
Waiting for deployment "demo-api" rollout to finish: 1 out of 2 new replicas have been updated...
error: timed out waiting for the condition

demo-api-5c7857b957-xw5hp 0/1 Running       <- new, never Ready
demo-api-689b965bd-swx5c  1/1 Running       <- old, still serving
demo-api-689b965bd-zh8gk  1/1 Running

Readiness probe failed: HTTP probe failed with statuscode: 500   (x17 over 85s)
```

Users saw **nothing** — `curl` during the stall still returned the old version.
That is `maxUnavailable: 0` plus a readiness probe doing their job. Without a
probe, Kubernetes would have marked the broken pod Ready and sent it traffic.

This is why `deployToEks` ends with `rollout status --timeout`: `kubectl apply`
returns success the moment the API server accepts the object. Only `rollout
status` tells the pipeline whether the new version actually came up.

**Two traps in the recovery:**

```
$ kubectl -n demo-ci rollout history deploy/demo-api
1   jenkins demo-api/main #2: .../demo-api:main-b3909666-2
2   jenkins demo-api/main #2: .../demo-api:main-b3909666-2     <- same text, different revision
```

The change-cause annotation is copied forward by `kubectl set env`, so the
history **lies** about what revision 2 was. And:

```
$ kubectl rollout undo deploy/demo-api
Warning: resource deployments/demo-api was previously managed with 'kubectl apply'.
Rolling back will not update the kubectl.kubernetes.io/last-applied-configuration annotation
```

`undo` is the emergency brake, not the fix. The fix is a commit, so git and
the cluster agree again.

## 5. Image tag does not exist

```
demo-api-b699cc99c-b9c8m  0/1  ErrImagePull
Failed to pull image "<acct>.dkr.ecr.us-east-1.amazonaws.com/platform-lab/demo-api:does-not-exist":
  rpc error: code = NotFound desc = failed to pull and unpack image ...
```

`NotFound` = wrong tag/repo. An auth problem says `401`/`403` instead. After a
few retries the status becomes `ImagePullBackOff` — same cause, just backing off.
Again the old pods kept serving.

## 6. Pending: "Insufficient memory" on a 5-node cluster

```
0/5 nodes are available: 5 Insufficient memory.
preemption: 0/5 nodes are available: 5 No preemption victims found for incoming pod.
```

A pod requesting 3Gi on t3.medium nodes. Five nodes do not add up to one big
node: a pod must fit **on one node**, and a t3.medium's *allocatable* memory is
`3371516Ki` (~3.2Gi) before daemonsets take their share. `kubectl describe node`
→ *Allocated resources* shows what is left.

---

## Not run here (yet) — know them anyway

- **Bad `@Library('platform-lib@nope')`** — fails before any stage, at library
  checkout. Pin library versions to tags for anything important; `main` means a
  library change can break every team's pipeline at once.
- **Script approval** — code in a *trusted* global library (configured by an
  admin, like `platform-lib` here) runs outside the Groovy sandbox. Code in a
  Jenkinsfile runs inside it and hits `RejectedAccessException`. That is the
  security boundary, and the reason logic belongs in the library.
