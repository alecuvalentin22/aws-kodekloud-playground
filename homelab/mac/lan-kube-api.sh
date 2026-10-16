#!/usr/bin/env bash
# Reach the RKE2 API from the home LAN WITHOUT the ssh tunnel: kubectl on the Mac
# (or any LAN machine with the kubeconfig) talks to https://192.168.1.153:6443.
#
#   homelab/mac/lan-kube-api.sh            add the PC's LAN address to the API cert, write the kubeconfig
#   homelab/mac/lan-kube-api.sh --yes      same, without the y/N question
#   homelab/mac/lan-kube-api.sh --undo     remove that address again, delete the LAN kubeconfig
#
# Why it is needed: HAProxy in WSL already forwards 192.168.1.153:6443 -> 10.77.0.31:6443
# (homelab/mac/lan-ingress.sh), but the API server's certificate only names 10.77.0.31
# and 127.0.0.1, so kubectl refuses it. RKE2 takes extra names from `tls-san`.
#
# What it changes: /etc/rancher/rke2/config.yaml on the SERVER VM only (roles/rke2_cluster,
# variable rke2_cluster_extra_sans, playbooks/rke2-sans.yml), then restarts rke2-server
# once. The API is unavailable for a minute or two; pods keep running; agents are not
# touched. If the served certificate does not pick the new name up by itself, the stored
# one (secret kube-system/rke2-serving) is deleted and rebuilt with a second restart.
# It writes homelab/generated/rke2-lan.kubeconfig (mode 600, git-ignored), derived from
# homelab/generated/rke2.kubeconfig; the credentials are copied, never printed.
#
# Keep in mind: anyone on the Wi-Fi can already reach port 6443 (README "LAN access");
# the client certificate in the kubeconfig is what authenticates. Treat that file like a
# cluster-admin password. Re-running playbooks/rke2-cluster.yml WITHOUT the variable
# drops the name again (it renders the same config.yaml); re-run this script after it.
#
# HOMELAB_LAN_IP   the address to add and to use    (default: 192.168.1.153)
# RKE2_SERVER_IP   the server VM, for the summary   (default: from homelab/generated/k8s.ini)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$(cd "$HERE/.." && pwd)"
GEN="$HERE/generated"
INV="$GEN/k8s.ini"
BASE="$GEN/rke2.kubeconfig"
OUT="$GEN/rke2-lan.kubeconfig"
SAN="${HOMELAB_LAN_IP:-192.168.1.153}"
CTX=homelab-rke2-lan

YES=0
UNDO=0
for a in "$@"; do
  case $a in
    --yes|-y) YES=1 ;;
    --undo) UNDO=1 ;;
    -h|--help) sed -n '5,7p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "lan-kube-api.sh: unknown argument '$a'" >&2; sed -n '5,7p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
  esac
done
die() { echo "lan-kube-api.sh: $*" >&2; exit 1; }

[[ $SAN =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || $SAN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
  || die "HOMELAB_LAN_IP='$SAN' is not an IPv4 address or a host name"
for tool in ansible-playbook kubectl openssl curl; do command -v "$tool" >/dev/null || die "$tool not found"; done
[[ -f $INV ]] || die "no $INV (made by playbooks/homelab-vms.yml)"
[[ -f $BASE ]] || die "no $BASE (made by playbooks/rke2-cluster.yml)"

# The server: first host of [rke2_servers] and its address.
SERVER_NAME="$(awk '/^\[rke2_servers\]/{f=1;next} /^\[/{f=0} f&&NF&&$1!~/^#/{print $1; exit}' "$INV")"
SERVER_IP="${RKE2_SERVER_IP:-$(sed -n "s/^${SERVER_NAME}[[:space:]].*ansible_host=\([^[:space:]]*\).*/\1/p" "$INV" | head -1)}"
[[ -n $SERVER_NAME && -n $SERVER_IP ]] || die "could not find the [rke2_servers] host in $INV"

# SANs of what 192.168.1.153:6443 serves, one per line. -text works on macOS' LibreSSL
# (which has no `x509 -ext`) as well as on OpenSSL 3.
served_sans() {
  echo | openssl s_client -connect "$SAN:6443" -servername "$SAN" 2>/dev/null \
    | openssl x509 -noout -text 2>/dev/null \
    | grep -A1 'Subject Alternative Name' | grep -o -E '(IP Address|DNS):[^,[:space:]]+' || true
}
has_san() {   # is "$SAN" among them?
  local want="DNS:$SAN"
  [[ $SAN =~ ^[0-9.]+$ ]] && want="IP Address:$SAN"
  served_sans | grep -Fxq "$want"
}
api_answers() { [[ "$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "https://$SAN:6443/version" 2>/dev/null)" =~ ^[1-5] ]]; }

# --- confirm --------------------------------------------------------------------------------
if [[ $UNDO -eq 0 ]]; then ACTION="ADD"; else ACTION="REMOVE"; fi
cat <<EOF
Target
  server VM : $SERVER_NAME ($SERVER_IP)   via $INV
  SAN       : $SAN   -> $ACTION in tls-san of /etc/rancher/rke2/config.yaml
  effect    : rke2-server restarts on that VM (API down for ~1-2 min; pods keep running)
  then      : $( [[ $UNDO -eq 0 ]] && echo "write $OUT (context $CTX, server https://$SAN:6443) and run kubectl get nodes" || echo "delete $OUT" )
EOF
if [[ $YES -eq 0 ]]; then
  read -r -p "Proceed? [y/N] " ans
  [[ $ans == y || $ans == Y ]] || { echo "aborted, nothing changed."; exit 0; }
fi

# --- 1. the server change ---------------------------------------------------------------------
cd "$LAB"
if [[ $UNDO -eq 0 ]]; then
  EV="{\"rke2_cluster_extra_sans\": [\"$SAN\"]}"
else
  EV="{\"rke2_cluster_sans_absent\": [\"$SAN\"]}"
fi
echo
echo "==> ansible-playbook playbooks/rke2-sans.yml -e '$EV'"
ansible-playbook -i "$INV" playbooks/rke2-sans.yml -e "$EV"

# --- 2. the API is back --------------------------------------------------------------------------
echo
echo "==> waiting for https://$SAN:6443 (through HAProxy)"
ok=0
for _ in $(seq 1 60); do
  if api_answers; then ok=1; break; fi
  sleep 5
done
[[ $ok -eq 1 ]] || die "https://$SAN:6443 does not answer after 5 minutes. Is this Mac on the PC's LAN, and is HAProxy up (homelab/mac/lan-ingress.sh)?"

# --- 3. the certificate, as seen from the Mac ------------------------------------------------------
echo
echo "==> subjectAltName served at $SAN:6443"
served_sans | sed 's/^/    /'
if [[ $UNDO -eq 0 ]]; then
  has_san || die "the served certificate does not contain $SAN (see the list above)"
  echo "    ok: contains $SAN"
else
  if has_san; then die "the served certificate still contains $SAN"; fi
  echo "    ok: $SAN is gone"
  rm -f "$OUT"
  echo "removed $OUT. Back to: homelab/mac/kube-tunnel.sh + homelab/generated/rke2.kubeconfig"
  exit 0
fi

# --- 4. the LAN kubeconfig (credentials copied, nothing printed) ----------------------------------------
echo
echo "==> $OUT"
umask 077
TMP="$(mktemp "$GEN/.rke2-lan.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
cp "$BASE" "$TMP"
chmod 600 "$TMP"
BASE_CTX="$(kubectl --kubeconfig "$BASE" config current-context)"
CLUSTER="$(kubectl --kubeconfig "$BASE" config view --minify -o 'jsonpath={.contexts[0].context.cluster}')"
kubectl --kubeconfig "$TMP" config set-cluster "$CLUSTER" --server "https://$SAN:6443" >/dev/null
[[ $BASE_CTX == "$CTX" ]] || kubectl --kubeconfig "$TMP" config rename-context "$BASE_CTX" "$CTX" >/dev/null
kubectl --kubeconfig "$TMP" config use-context "$CTX" >/dev/null
mv "$TMP" "$OUT"
trap - EXIT
chmod 600 "$OUT"
echo "    written, mode $(stat -f %Lp "$OUT" 2>/dev/null || stat -c %a "$OUT"): context $CTX, server $(kubectl --kubeconfig "$OUT" config view --minify -o 'jsonpath={.clusters[0].cluster.server}')"

# --- 5. prove it -----------------------------------------------------------------------------------------
echo
echo "==> KUBECONFIG=$OUT kubectl get nodes"
kubectl --kubeconfig "$OUT" --request-timeout=30s get nodes
echo
echo "Use it:  export KUBECONFIG=$OUT   (no tunnel needed)"
