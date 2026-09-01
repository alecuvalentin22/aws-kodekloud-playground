#!/usr/bin/env bash
# Create the APISIX Admin API key Secret.
#
#   ./scripts/apisix-bootstrap-secret.sh        # or: make apisix-secret
#
# THE ONE IMPERATIVE STEP, and it is the same chicken-and-egg every
# encryption-at-rest scheme has somewhere.
#
# The Admin API key authorises rewriting every route in the gateway, so it must
# not be a literal in git -- which rules out putting it in the Helm valuesObject.
# The GatewayProxy therefore references a Secret by name. But a Secret that
# nothing in git creates is a Secret that does not exist on a fresh cluster, and
# the symptom is indirect: the controller cannot authenticate to the Admin API,
# so it pushes nothing, so the gateway 404s every route while every pod is
# Running.
#
# Three ways to close it, and this repo has opinions about all three:
#
#   1. THIS SCRIPT -- generate a random key, kubectl create secret. Honest,
#      trivially reproducible, and the cluster is not self-describing: the key
#      exists nowhere but the cluster.
#   2. SealedSecret -- commit ciphertext, sealed-secrets decrypts it. Fully
#      GitOps, but the sealing key is per-cluster, so a REBUILT cluster cannot
#      decrypt what is committed (see gitops/secrets/README.md). On a throwaway
#      playground that is a guarantee of breakage, not a risk.
#   3. SOPS + age -- commit ciphertext, kustomize-controller decrypts. Same
#      shape, but the age key survives cluster rebuilds because YOU hold it.
#      This is the right answer for a lab that is rebuilt daily, and it moves
#      the bootstrap to "get the age key into the cluster" rather than removing
#      it.
#
# None of them removes the bootstrap. They move it. Say that out loud rather
# than claiming a fully-declarative secret story.
set -euo pipefail

CLUSTER="${CLUSTER:-andrei-lab-eks}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CLUSTER}"
NS="${APISIX_NS:-apisix}"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if kubectl -n "$NS" get secret apisix-admin >/dev/null 2>&1; then
  echo "==> secret/apisix-admin already exists -- leaving it alone"
  exit 0
fi

# NOT the chart default (edd1c9f034335f136f87ad84b625c8f1), which is published
# in every APISIX tutorial and in the chart's own values.yaml.
kubectl -n "$NS" create secret generic apisix-admin \
  --from-literal=key="$(openssl rand -hex 24)" >/dev/null
echo "==> generated secret/apisix-admin (48 hex chars, not the published default)"
echo "    the GatewayProxy reads it via valueFrom.secretKeyRef -- nothing in git"
