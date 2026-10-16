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
kubectl apply -f homelab/argocd/ingress.yaml

kubectl -n argocd get deploy argocd-server -o jsonpath='{..image}'   # quay.io/argoproj/argocd:v3.5.2
```

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
