# Drill 07 — Rancher vs RKE2 (why the lab uses k3s)

The confusion is worth clearing up precisely, because the JD says *Rancher*, and
people assume that means RKE2.

| | What it is |
|---|---|
| **Rancher** | A **management plane**. A web UI and API that manages clusters, users, RBAC, projects, catalogs, and Fleet GitOps. It runs *as an application on* a Kubernetes cluster. |
| **RKE2** | A **Kubernetes distribution** by SUSE. Hardened, FIPS-capable, CIS-benchmarked, systemd-managed, static pods for the control plane. |
| **k3s** | Another SUSE distribution. Single binary, lightweight, same conformant Kubernetes API. |

**The key point:** Rancher manages *any* conformant cluster. RKE2, k3s, EKS, AKS,
OpenShift, a kubeadm cluster — you import it and Rancher manages it. RKE2 is not
a prerequisite for Rancher and Rancher is not a prerequisite for RKE2.

So the lab runs Rancher on k3s. You get genuine Rancher experience — the UI,
projects and namespaces, RBAC, cluster import, Fleet — in a fraction of the
resources, and every Rancher skill transfers unchanged to an RKE2-managed estate.

## What to know about RKE2 without running it
- Installed via a systemd service (`rke2-server`, `rke2-agent`), config in
  `/etc/rancher/rke2/config.yaml`, kubeconfig at `/etc/rancher/rke2/rke2.yaml`.
- Control plane runs as **static pods** (not systemd units like RKE1), so
  `crictl ps` is your friend when the API server will not start.
- Ships containerd, and Canal (Calico+Flannel) as default CNI.
- The selling point over k3s is hardening: CIS profiles, FIPS 140-2 crypto, no
  embedded SQLite default — which is why regulated environments pick it.
- Upgrades are driven by the **system-upgrade-controller** with Plan CRDs, which
  is also how Rancher does managed cluster upgrades.

## Running RKE2 instead of k3s in this lab

Both are just a shell script onto an Ubuntu box -- neither depends on any AWS
service, so both install fine on a KodeKloud playground instance. RKE2 wants
~4 GB, which is exactly what a t3.medium gives you.

```yaml
# inventory/group_vars/all.yml
k8s_distribution: rke2      # or k3s
```

Then `ansible-playbook playbooks/k8s.yml`. Everything above it -- Helm,
cert-manager, Rancher, Kong -- is identical, which is itself the lesson: the
distribution is swappable, the management plane is not.

Worth doing **both at least once** so you can say you have. The differences you
will actually notice:

| | k3s | RKE2 |
|---|---|---|
| Service unit | `k3s` | `rke2-server` / `rke2-agent` |
| Config file | CLI flags | `/etc/rancher/rke2/config.yaml` |
| Kubeconfig | `/etc/rancher/k3s/k3s.yaml` | `/etc/rancher/rke2/rke2.yaml` |
| kubectl | on PATH | `/var/lib/rancher/rke2/bin/kubectl` |
| Control plane | inside the k3s process | **static pods** -- debug with `crictl ps` |
| Default CNI | Flannel | Canal (Calico + Flannel) |
| Datastore | embedded SQLite | embedded etcd |
| Hardening | none by default | CIS profiles, FIPS 140-2 builds |

That `crictl ps` line is the one that separates people who have run RKE2 from
people who have read about it. If the API server is down, `systemctl status
rke2-server` tells you almost nothing -- you go to the containerd runtime.

## Do this (30 minutes, worth it)
1. Log into Rancher, import your k3s cluster if it is not already there.
2. Create a **Project**, put two namespaces in it, and bind a user with
   read-only access. This is RBAC, which you already do daily on OpenShift.
3. Deploy something from the Apps catalog.
4. Add a **Fleet** GitRepo pointing at this repository's `kubernetes/` folder.

## Say this in the interview
> "I run Rancher on k3s in my lab. Rancher is the management plane — it'll manage
> RKE2, k3s, EKS or an imported cluster equally; the distro underneath is an
> implementation detail. RKE2 is the hardened distribution you'd pick for a
> regulated environment, and it differs mainly in running the control plane as
> static pods and shipping CIS and FIPS profiles."


---

# What Rancher is actually FOR (added after building both)

Installing Rancher on k3s and again on RKE2 proves only that it installs. The
claim worth making is the one in Rancher's own description: it is a **multi-
cluster manager**, and it does not care what is underneath.

## The topology that demonstrates it

```
rke2-01   RKE2   "local"     <- Rancher runs here
k3s-01    k3s    "k3s-lab"   <- imported, managed remotely
```

One command:

```bash
ansible-playbook playbooks/rancher-import.yml --ask-vault-pass
```

It logs into the Rancher API, creates an **imported** cluster (no provider
config -- that is what distinguishes "imported" from "provisioned"), mints a
registration token, and applies the resulting manifest on the downstream
cluster.

**Note the direction of the connection.** The `cattle-cluster-agent` on the
downstream cluster dials *out* to Rancher. Rancher never connects inward. That
is why this works across NAT, across VPCs and across accounts without opening a
single inbound port on the managed cluster -- and it is the answer to "how would
you manage a customer's cluster you have no network access to?"

## The four things this unlocks

**Clusters.** Two Kubernetes distributions, one pane. Switch between them in the
UI and the workload views are identical, because Rancher talks to the Kubernetes
API and both are conformant. That *is* the "it doesn't care what's underneath"
claim, made concrete.

**Projects.** Rancher's own abstraction, sitting **above** namespaces -- there is
no such object in vanilla Kubernetes. Group `kong` and `keycloak` into a
"gateway" project and they share quota, network policy defaults and access
control as a unit.

**RBAC that vanilla Kubernetes cannot express.** Bind a user to a *project* and
they get every namespace in it -- **including namespaces created later**. In
plain Kubernetes you would need a RoleBinding per namespace and something to
create the next one. This is the strongest single argument for Rancher in an
interview.

**Helm to a cluster whose kubeconfig you never touch.** Deploy from Rancher's
catalog, targeted at the downstream cluster. The credential stays with Rancher;
you were never handed cluster-admin on the managed cluster at all.

## Say this in the interview

> "Rancher's value isn't that it installs Kubernetes -- it's that it manages
> clusters it didn't create. I ran it on RKE2 and imported a k3s cluster, so one
> control plane governed two different distributions.
>
> The mechanic worth knowing is that the cluster agent dials *out* to Rancher.
> Rancher never connects inward, so you can manage a cluster behind NAT in
> someone else's account without any inbound access.
>
> And the feature that isn't just a UI convenience is Projects. A project sits
> above namespaces, and binding a user to one grants access to namespaces that
> don't exist yet. Vanilla Kubernetes RBAC can't express that -- you'd need a
> RoleBinding per namespace and automation to keep up."
