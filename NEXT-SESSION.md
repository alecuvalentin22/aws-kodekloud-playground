# Next session — paste this

> Continue the AWS GitOps lab in `~/gcp/platform-lab`
> (github.com/alecuvalentin22/aws-kodekloud-playground).
> **Read `AGENTS.md` first** — it has the credential flow, the 3-hour IAM window,
> the EKS permission map and the traps that already cost time.
>
> I've put fresh KodeKloud creds in `~/gcp/aws-lab-creds`.
>
> Rebuild the cluster and then finish what we never got working, roughly in this
> order:
>
> **1. Fix pod density FIRST — this blocked us last time.**
> EKS caps pods per node by ENI, not CPU: a t3.medium allows only 17, and
> Argo CD + Flux + Rollouts + ingress-nginx + Flagger + Prometheus exceeds three
> nodes. Set `ENABLE_PREFIX_DELEGATION=true` on the `aws-node` daemonset
> **before the nodes launch** (it only applies to nodes joining afterwards,
> because kubelet computes max-pods at bootstrap), and/or raise `node_max_size`
> above 3 in `terraform/eks/variables.tf`.
>
> **2. Flagger, complete.** It initialised last time but its analysis never ran.
> Get a full canary through: progressing → promoting → succeeded, plus a
> deliberate bad release that Flagger rolls back on its own. That is the one
> thing Argo Rollouts did NOT do for us.
>
> **3. Argo Rollouts with real traffic routing.** Wire `trafficRouting` to
> ingress-nginx so there is a genuine canary Service. Then redo the
> AnalysisTemplate — last time it reported `Successful` while a pod was broken,
> because without traffic routing it was checking the stable Service backed by
> healthy old pods. Prove automatic rollback.
>
> **4. A/B routing** — header or cookie based, on top of #3.
>
> **5. Flux Operator + Flux Web UI**
> (github.com/controlplaneio-fluxcd/flux-operator, AGPL-3.0). Declarative
> `FluxInstance` instead of `flux install`, plus the web UI on
> `port-forward svc/flux-operator 9080`. Also look at its `ResourceSet` APIs —
> ephemeral PR environments are Flux's answer to Argo's PR generator.
>
> **6. Secrets** — sealed-secrets or SOPS+age, since ciphertext is safe in a
> public repo. Currently deliberately absent.
>
> **7. Helm through GitOps** — everything so far is kustomize. Flux `HelmRelease`
> and an Argo CD Helm source.
>
> **8. Argo CD webhook** — would collapse the measured 155s git-to-live to
> seconds. Needs the API reachable from GitHub, which may not be possible on a
> playground; say so if it isn't.
>
> Add each as a numbered scenario under `gitops/scenarios/` with the existing
> three-function shape, and **measure everything** — the repo's value is that no
> claim is quoted from documentation.
>
> When done, update the two existing artifacts rather than making new ones (URLs
> are in `AGENTS.md`; pass them as `url` or the shared links go stale).
>
> Two rules already learned the hard way: never suppress the output of the thing
> whose failure you are testing, and break things through **git**, not `kubectl`
> — otherwise you measure Argo CD's selfHeal instead of a bad release.

---

## Also outstanding (no cluster needed)

- **`~/gcp/STORY.md` is GCP-only.** It needs an AWS counterpart covering the
  platform lab, the EKS permission archaeology, the Argo CD vs Flux measurements
  and the scenario harness.

## Eventually: port to GCP

Same manifests, same scenarios, GKE instead of EKS. The specific thing to hunt
for: **GKE uses an overlay network**, so the pods-per-node ENI wall that blocked
Flagger on EKS should not exist there. Same config, one materially different
constraint — that is a real cross-cloud finding rather than a guess.
