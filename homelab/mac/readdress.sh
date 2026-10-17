#!/usr/bin/env bash
# New router / new LAN address: move the whole lab to it -- from the Mac.
#
#   homelab/mac/readdress.sh 192.168.0.23                  rewrite repo + local files, then apply
#   homelab/mac/readdress.sh 192.168.0.23 192.168.0.0/24   same, with an explicit LAN (default: <ip>/24)
#   homelab/mac/readdress.sh 192.168.0.23 --files-only     only rewrite files, touch nothing on the PC
#
# Do homelab/windows/readdress.ps1 ON THE PC first: until it has run, the Windows
# firewall drops everything from the new subnet, SSH included (START-HERE.md).
#
# What it does:
#   1. every git-tracked file naming the old IP / old LAN (homelab/lan.env) is rewritten:
#      nip.io hostnames of every Ingress, homepage, uptime probes, Jenkins/Backstage URLs,
#      script defaults, docs. Plus homelab/lan.env itself.
#   2. local, git-ignored files: ~/.ssh/config.d/homelab (HostName), ~/.ssh/known_hosts
#      (the PC's SAME host keys copied to the new IP -- no blind "accept new key"),
#      homelab/inventory.ini, homelab/generated/rke2-lan.kubeconfig.
#   3. applies what holds the address outside git:
#      - the WSL forwarder (HAProxy binds the playground ports to the LAN IP): lan-ingress.sh --ansible
#      - the API certificate gets the new IP: lan-kube-api.sh --yes
#      - Argo CD's own Ingress (not managed by Argo): kubectl apply -k homelab/argocd
#   4. prints the git commands: Argo CD syncs the rest from the branch once it is pushed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$(cd "$HERE/.." && pwd)"
NEW=${1:?usage: readdress.sh <new-ip> [<new-cidr>] [--files-only]}
shift
NEW_CIDR=""; FILES_ONLY=0
for a in "$@"; do case $a in --files-only) FILES_ONLY=1 ;; */*) NEW_CIDR=$a ;; *) echo "unknown argument: $a" >&2; exit 2 ;; esac; done
ip_re='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
[[ $NEW =~ $ip_re ]] || { echo "not an IPv4 address: $NEW" >&2; exit 2; }
[[ -n $NEW_CIDR ]] || NEW_CIDR="${NEW%.*}.0/24"
[[ $NEW_CIDR =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || { echo "not a CIDR: $NEW_CIDR" >&2; exit 2; }
# shellcheck source=/dev/null
source "$HERE/lan.env"
OLD=$HOMELAB_LAN_IP OLD_CIDR=$HOMELAB_LAN_CIDR
say() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[32mok\033[0m  %s\n' "$*"; }

# Replace an address only where it stands alone: 192.168.1.15 must not hit 192.168.1.153.
rewrite() {   # $1 old  $2 new  $3.. files
  local o=$1 n=$2; shift 2
  [[ $# -gt 0 ]] || return 0
  O="$o" N="$n" perl -pi -e 's/(?<![\d])(?<!\d\.)\Q$ENV{O}\E(?![\d])/$ENV{N}/g' "$@"
}

if [[ $OLD == "$NEW" && $OLD_CIDR == "$NEW_CIDR" ]]; then
  echo "homelab/lan.env already says $NEW ($NEW_CIDR): nothing to rewrite."
else
  say "Repo: $OLD -> $NEW, $OLD_CIDR -> $NEW_CIDR"
  cd "$LAB"
  files=()
  while IFS= read -r f; do files+=("$f"); done < <(git grep -lF -e "$OLD" -e "$OLD_CIDR" -- . ':!homelab/lan.env' || true)
  if [[ ${#files[@]} -gt 0 ]]; then
    rewrite "$OLD_CIDR" "$NEW_CIDR" "${files[@]}"
    rewrite "$OLD" "$NEW" "${files[@]}"
  fi
  rewrite "$OLD" "$NEW" homelab/lan.env
  rewrite "$OLD_CIDR" "$NEW_CIDR" homelab/lan.env
  ok "${#files[@]} tracked files + homelab/lan.env"

  say "Local files (git-ignored)"
  for f in "$HOME/.ssh/config.d/homelab" "$HERE/inventory.ini" "$HERE/generated/rke2-lan.kubeconfig"; do
    [[ -f $f ]] || continue
    grep -qF "$OLD" "$f" && { rewrite "$OLD" "$NEW" "$f"; ok "$f"; }
  done
  # Same PC, same host keys: copy its known_hosts entries to the new address.
  if [[ -f ~/.ssh/known_hosts ]] && ! ssh-keygen -F "$NEW" >/dev/null 2>&1; then
    n=0
    while read -r _ type key; do
      echo "$NEW $type $key" >> ~/.ssh/known_hosts; n=$((n + 1))
    done < <(ssh-keygen -F "$OLD" 2>/dev/null | grep -v '^#')
    [[ $n -gt 0 ]] && ok "known_hosts: $n host key(s) of $OLD now also listed for $NEW"
  fi
fi

if [[ $FILES_ONLY == 1 ]]; then echo; echo "--files-only: nothing applied on the PC."; exit 0; fi

say "Apply on the lab"
ssh -n -o BatchMode=yes -o ConnectTimeout=10 homelab-1 'exit 0' \
  || { echo "ssh homelab-1 ($NEW) does not answer: run homelab/windows/readdress.ps1 on the PC first (START-HERE.md)." >&2; exit 1; }
ok "ssh homelab-1 -> $NEW"
"$HERE/mac/lan-ingress.sh" --ansible
HOMELAB_LAN_IP="$NEW" "$HERE/mac/lan-kube-api.sh" --yes
KUBECONFIG="$HERE/generated/rke2-lan.kubeconfig" \
  kubectl apply --server-side --field-manager=homelab-argocd -k "$HERE/argocd"
ok "Argo CD ingress -> argocd.$NEW.nip.io"

say "Left for you"
cat <<MSG
    git -C "$LAB" commit -am "homelab: move to $NEW ($NEW_CIDR)" && git -C "$LAB" push
      (Argo CD then re-syncs every Ingress, the homepage and the probes from the branch)
    Router: reserve $NEW for the PC's MAC, so the next reboot does not move it again.
    Start page: http://home.$NEW.nip.io
MSG
