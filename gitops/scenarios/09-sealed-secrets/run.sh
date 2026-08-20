# QUESTION: Can a secret live in a PUBLIC git repo and still be a secret?
# EXPECT: Yes -- and the failure mode is a rebuilt cluster, not a leak.
#
# Two properties get checked here, and only the first is the one people demo:
#   1. the committed ciphertext decrypts into a real Secret
#   2. the ciphertext does NOT decrypt in a different namespace
#
# (2) is what makes SealedSecrets usable in a shared repo. The namespace is
# inside the encrypted envelope, so a tenant cannot copy another tenant's
# ciphertext into their own directory and have the controller open it for them.
# SOPS has no equivalent: whoever holds the age key decrypts everything.

scenario_apply() {
  [[ "$CTL" == "argocd" ]] || { echo "    (controller-agnostic; run once)"; return 0; }
  kubectl get crd sealedsecrets.bitnami.com >/dev/null 2>&1 || {
    echo "    sealed-secrets not installed; ./scripts/gitops-addons.sh sealed-secrets"; return 1; }

  kubectl apply -f "$ROOT/gitops/secrets/namespace.yaml" 2>&1 | sed 's/^/      /'
  echo "    applying the committed ciphertext"
  kubectl apply -f "$ROOT/gitops/secrets/sealed/demo-credentials.yaml" 2>&1 | sed 's/^/      /'
}

scenario_observe() {
  [[ "$CTL" == "argocd" ]] || return 0

  echo
  echo "    what is in git (first 3 lines of the encrypted value):"
  grep -A3 'encryptedData' "$ROOT/gitops/secrets/sealed/demo-credentials.yaml" \
    | cut -c1-88 | sed 's/^/      /'

  echo
  echo "    waiting for the controller to unseal it..."
  for i in $(seq 1 12); do
    kubectl -n demo-secrets get secret demo-credentials >/dev/null 2>&1 && break
    sleep 5
  done

  if kubectl -n demo-secrets get secret demo-credentials >/dev/null 2>&1; then
    echo "    Secret/demo-credentials exists. Keys:"
    kubectl -n demo-secrets get secret demo-credentials -o jsonpath='{range .data.*}{"\n"}{end}' >/dev/null
    kubectl -n demo-secrets get secret demo-credentials -o go-template='{{range $k,$v := .data}}      {{$k}} = {{len $v}} bytes of base64{{"\n"}}{{end}}'
  else
    echo "    NOT unsealed. The usual cause is a REBUILT CLUSTER: kubeseal encrypts"
    echo "    against the controller's public cert, and a fresh controller generates"
    echo "    a fresh key, so every SealedSecret already in git is now undecryptable."
    kubectl -n demo-secrets get sealedsecret demo-credentials \
      -o jsonpath='      {.status.conditions[0].message}{"\n"}' 2>/dev/null
    echo "    Re-seal with ./scripts/secrets-seal.sh -- and note that this is a real"
    echo "    operational property, not a lab artefact: back the sealing key up."
    return 0
  fi

  echo
  echo "    now the namespace-binding test -- same ciphertext, different namespace:"
  kubectl create ns demo-secrets-evil --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  sed 's/namespace: demo-secrets/namespace: demo-secrets-evil/' \
    "$ROOT/gitops/secrets/sealed/demo-credentials.yaml" | kubectl apply -f - 2>&1 | sed 's/^/      /'
  sleep 10
  if kubectl -n demo-secrets-evil get secret demo-credentials >/dev/null 2>&1; then
    echo "      UNEXPECTED: it decrypted. Check that --scope strict was used."
  else
    echo "      refused, as designed:"
    kubectl -n demo-secrets-evil get sealedsecret demo-credentials \
      -o jsonpath='        {.status.conditions[0].message}{"\n"}' 2>/dev/null
  fi
  echo
  echo "    -> the namespace is part of the encrypted envelope, not a label on it"
}

scenario_reset() {
  [[ "$CTL" == "argocd" ]] || return 0
  kubectl delete ns demo-secrets-evil --wait=false >/dev/null 2>&1
  return 0
}
