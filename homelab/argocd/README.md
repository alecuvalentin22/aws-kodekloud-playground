# Argo CD on the home-lab RKE2 cluster

Version: **v3.5.2**, pinned as `ARGOCD_VERSION` in [`versions.env`](../../versions.env).
Installed from the official manifest for exactly that tag, with server-side
apply (Argo CD's CRDs are too large for client-side apply's annotation).

## Install

Needs the kube tunnel (below) and `KUBECONFIG=homelab/generated/rke2.kubeconfig`.

```bash
. <(grep '^ARGOCD_VERSION=' versions.env | sed 's/ *#.*//')
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml
kubectl -n argocd rollout status deploy,sts --timeout=300s
kubectl apply --server-side --field-manager=homelab-argocd -k homelab/argocd   # ingress + argocd-cm health check

kubectl -n argocd get deploy argocd-server -o jsonpath='{..image}'   # quay.io/argoproj/argocd:v3.5.2
```

## Application health check (what makes sync waves gate)

`install.yaml` ships no health assessment for `argoproj.io/Application` (removed in
Argo CD 1.8). Without one, every child Application of `homelab-platform` counts as
Healthy the moment it exists, so wave 1 does not wait for wave 0 and the
`argocd.argoproj.io/sync-wave` annotations in `homelab/platform/apps/` order the
*creation* of Applications but gate nothing. [`argocd-cm.yaml`](argocd-cm.yaml) adds the
Lua from the Argo CD docs ("Resource Health" > "Argocd App") as
`resource.customizations.health.argoproj.io_Application`: a child is as healthy as its
own `status.health`, and Progressing until it has one.

It is a partial ConfigMap with only that key, applied server-side under its own field
manager, so reapplying `install.yaml` with `--force-conflicts` neither removes it nor
fights over `argocd-cm`. Reapply (idempotent; the Mac needs the kube tunnel):

```bash
kubectl apply --server-side --field-manager=homelab-argocd -k homelab/argocd
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data}' | grep -c argoproj.io_Application   # 1
```

A consequence: the root app is now only Healthy when every wave is, so a failing
last-wave app (Artifactory) shows `homelab-platform` as Degraded/Progressing.

## Reach the UI from the Mac

The VMs sit on the Incus bridge inside WSL, which nothing outside the PC can
route to. Forward the ingress port through the same SSH chain, then browse to
the nip.io name (it resolves to 127.0.0.1, so the tunnel is the way in):

```bash
ssh -f -N -L 8443:10.77.0.31:443 homelab-1-wsl
open https://argocd.127.0.0.1.nip.io:8443/          # self-signed cert: accept it
curl -sk -o /dev/null -w '%{http_code}\n' https://argocd.127.0.0.1.nip.io:8443/   # 200
pkill -f 'ssh -f -N -L 8443:10.77.0.31:443'          # stop the tunnel
```

[`ingress.yaml`](ingress.yaml): host `argocd.127.0.0.1.nip.io`,
`ingressClassName: nginx`, `backend-protocol: HTTPS` (argocd-server serves TLS).

## Initial admin password (never printed)

User `admin`. Straight to the clipboard, so it never lands in a terminal or log:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d | pbcopy
```

Change it after the first login, then delete the secret
(`kubectl -n argocd delete secret argocd-initial-admin-secret`).
