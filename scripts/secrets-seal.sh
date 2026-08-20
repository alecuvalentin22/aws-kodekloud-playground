#!/usr/bin/env bash
# Produce the two committable ciphertexts in gitops/secrets/ from one plaintext.
#
#   ./scripts/secrets-seal.sh
#
# Both outputs are safe in a public repository. The plaintext and the age
# private key are written to a temp dir and are NOT.
#
# Requires a live cluster with the sealed-secrets controller running: kubeseal
# fetches the controller's public certificate from it. That is a real
# constraint, not an implementation detail -- see gitops/secrets/README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$HERE/gitops/secrets"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

command -v kubeseal >/dev/null || { echo "kubeseal not on PATH (brew install kubeseal)" >&2; exit 1; }
command -v sops     >/dev/null || { echo "sops not on PATH (brew install sops)" >&2; exit 1; }
command -v age-keygen >/dev/null || { echo "age not on PATH (brew install age)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. plaintext -- generated, never typed, never committed
# ---------------------------------------------------------------------------
API_TOKEN="lab-$(openssl rand -hex 12)"
DB_PASSWORD="$(openssl rand -base64 18)"

cat > "$WORK/plain.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: demo-credentials
  namespace: demo-secrets
type: Opaque
stringData:
  api-token: "$API_TOKEN"
  db-password: "$DB_PASSWORD"
EOF

# ---------------------------------------------------------------------------
# 2. Sealed Secrets
#
# --scope strict (the default) binds the ciphertext to BOTH the namespace and
# the name. Copying this file into another namespace produces a decryption
# failure rather than a leaked secret.
# ---------------------------------------------------------------------------
echo "==> sealing with the cluster's public cert"
kubeseal --format yaml \
  --controller-namespace kube-system \
  --controller-name sealed-secrets-controller \
  --scope strict \
  < "$WORK/plain.yaml" > "$OUT/sealed/demo-credentials.yaml"
echo "    -> gitops/secrets/sealed/demo-credentials.yaml"

# ---------------------------------------------------------------------------
# 3. SOPS + age
#
# The private key goes into the cluster as an ordinary Secret. That bootstrap
# step cannot itself be encrypted with SOPS, which is the chicken-and-egg every
# encryption-at-rest scheme has somewhere.
# ---------------------------------------------------------------------------
echo "==> generating an age key pair"
age-keygen -o "$WORK/age.key" 2>/dev/null
PUB="$(grep -oE 'age1[a-z0-9]+' "$WORK/age.key" | head -1)"
echo "    public key: $PUB"

# Point .sops.yaml at the key we just made.
python3 - "$HERE/.sops.yaml" "$PUB" <<'PY'
import re, sys
p, pub = sys.argv[1], sys.argv[2]
s = open(p).read()
s = re.sub(r'age1[a-z0-9]+', pub, s)
open(p, 'w').write(s)
PY

cp "$WORK/plain.yaml" "$OUT/sops/demo-credentials.yaml"
( cd "$HERE" && sops --encrypt --in-place "gitops/secrets/sops/demo-credentials.yaml" )
echo "    -> gitops/secrets/sops/demo-credentials.yaml"

if kubectl get ns flux-system >/dev/null 2>&1; then
  echo "==> loading the age private key into flux-system"
  kubectl -n flux-system create secret generic sops-age \
    --from-file=age.agekey="$WORK/age.key" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "    Secret/sops-age created -- referenced by spec.decryption in the Kustomization"
fi

cat <<EOF

Both ciphertexts are safe to commit. Verify that claim rather than trusting it:

  grep -c "$API_TOKEN" $OUT/sealed/demo-credentials.yaml $OUT/sops/demo-credentials.yaml
  # both must be 0

The age PRIVATE key existed only in $WORK and is now deleted. If you need to
re-encrypt later, run this script again -- it rotates the key, which is fine,
because nothing else is encrypted to it.
EOF
