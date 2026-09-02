# Continuing this work

Everything the previous version of this file listed as outstanding is **done and
measured**: pod density, Flagger end to end, Argo Rollouts with real traffic
routing, A/B, Flux Operator + Web UI + ResourceSet, secrets, Helm, and the
Argo CD webhook. See `AGENTS.md` section 4c–4d for the numbers and `STORY-AWS.md` for
what they mean.

What follows is what is genuinely left.

---

## Paste this to rebuild and continue

> Continue the AWS GitOps lab in `~/gcp/platform-lab`
> (github.com/alecuvalentin22/aws-kodekloud-playground). **Read `AGENTS.md`
> first** — it has the credential flow, the 3-hour IAM window, the EKS permission
> map, and the traps that already cost time.
>
> Fresh KodeKloud creds are in `~/gcp/aws-lab-creds`.
>
> Rebuild with **`./scripts/eks-up.sh`** — not `terraform apply`. It runs three
> phases so prefix delegation is on the CNI daemonset *before* any node joins;
> kubelet reads `max-pods` once at bootstrap and a node that joins early is stuck
> at 17 pods and has to be terminated. Then `./scripts/gitops-install.sh` and
> `./scripts/gitops-addons.sh`. Confirm `kubectl get nodes -o custom-columns=
> 'N:.metadata.name,P:.status.allocatable.pods'` reads **110**, not 17, before
> installing anything.
>
> Then pick up from "What is actually left" below.

---

## What is actually left

**1. Multi-cluster GitOps.** The one structural thing neither controller has
been shown doing here. Argo CD registers external clusters as secrets and one
control plane drives many; Flux runs a controller per cluster and federates
through git. That difference is bigger than anything measured so far. Needs two
clusters — likely 2 EKS control planes with 2 nodes each, which fits the 5
instance ceiling only just.

**2. Image automation.** Flux's image-reflector and image-automation controllers
write commits back to the repo. Deliberately **not** installed: this repo is also
reconciled by Argo CD, and two controllers with push access to one branch is a
bad idea. Doing it properly means a separate branch or repo, which is itself the
interesting design question.

**3. Progressive delivery on real metrics.** Everything so far is driven by a
synthetic load generator. Latency and error-rate gates against actual traffic
behave differently — particularly the "no values found" failure mode, which in
production means *low traffic*, not *no metrics*.

**4. Register the Argo CD webhook with GitHub.** The endpoint is proven working
(signed payload → HTTP 200 → both Applications refreshed instantly), but this
laptop has no `gh` CLI and the git remote is SSH, so the last step is manual.
`./scripts/argocd-webhook.sh` prints the exact URL, secret and settings. Then
re-run scenario 11 and scenario 04 to measure git-to-live against the 155s
baseline. **Note the playground IP changes on every rebuild, so the hook has to
be re-pointed each time** — which is itself a fair argument that webhooks want a
stable ingress, not a NodePort.

**5. ResourceSet PR environments, actually exercised.** Configured and Ready,
rendering an empty set because no pull request carries the `preview` label.
Open one against the public repo to see it materialise — and note that an empty
input list looks identical to a broken provider.

---

## Port to GCP

`~/gcp/STORY.md` is the GCP write-up; `STORY-AWS.md` is its counterpart, shaped
the same way on purpose. The comparison table at the end of `STORY-AWS.md` is
the deliverable.

**The specific thing to hunt for: the pod-density wall should disappear.** GKE
gives pods addresses on an overlay network, so there is no ENI ceiling — the same
manifest set that needs prefix delegation on three EKS `t3.medium`s should simply
fit on three GKE `e2-medium`s with no equivalent setting. If that is confirmed,
it is the strongest single row in the AWS-vs-GCP table, because it is a
consequence of a deliberate architectural choice on both sides rather than a
quirk.

Second thing to check: whether GCP's org policies deny at the API call the way an
AWS SCP does, or late and asynchronously the way `allowedMaxDiskSize` did.

---

## Rules that are not negotiable

**Break things through git, not `kubectl`.** Otherwise you measure Argo CD's
selfHeal instead of a bad release. This bit twice — once in scenario 05, once
patching an AppProject that then looked like a slow sync for 200s.

**Never suppress the output of the thing whose failure you are testing, and
assert before you conclude.** A scenario that prints its expected conclusion
unconditionally is not a measurement. Both existing examples are documented in
`gitops/scenarios/README.md`.

**Check the tag exists.** `podinfo:6.7.2` does not. Flagger reported "canary
deployment not ready" and then "Canary failed! Scaling down", which is
indistinguishable from a metric-driven rollback at a glance.

**Update the artifacts in place.** URLs are in `AGENTS.md` section 0b and
`artifacts/README.md`; sources are in `artifacts/`. Pass the URL as `url` when
publishing from a new conversation or the shared links go stale.
