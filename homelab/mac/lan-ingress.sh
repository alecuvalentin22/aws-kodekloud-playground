#!/usr/bin/env bash
# Make the lab answer on the home LAN -- from the Mac: ingress 80/443, RKE2 API 6443,
# the playground's 30094/30095/30300 (ports: lan-ingress.ps1 -Ports, homelab_lan_tcp_forwards).
#
#   homelab/mac/lan-ingress.sh               Windows firewall rules, then the forwarder in WSL
#   homelab/mac/lan-ingress.sh --windows     only the Windows side (lan-ingress.ps1)
#   homelab/mac/lan-ingress.sh --ansible     only the forwarder (roles/homelab, --tags lan_ingress)
#   homelab/mac/lan-ingress.sh --uninstall   remove both rules, stop and disable the forwarder
#
# What is exposed, to whom, and how to undo it: homelab/README.md "LAN access".
#
# HOMELAB_SSH       ssh alias of the Windows PC          (default: homelab-1)
# HOMELAB_LAN_CIDR  who may connect                      (default: the PC's own LAN subnet)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$(cd "$HERE/.." && pwd)"
HOST="${HOMELAB_SSH:-homelab-1}"
INV="$HERE/inventory.ini"
MODE="${1:-all}"
case $MODE in all|--windows|--ansible|--uninstall) ;; *) sed -n '2,10p' "${BASH_SOURCE[0]}" >&2; exit 2 ;; esac

windows() {   # $1 = extra lan-ingress.ps1 arguments
  ssh -o BatchMode=yes "$HOST" 'exit 0' || { echo "ssh $HOST does not work: see homelab/README.md step 0" >&2; exit 1; }
  scp -q "$HERE/windows/lan-ingress.ps1" "$HOST:lan-ingress.ps1"
  local from=""; [[ -n ${HOMELAB_LAN_CIDR:-} ]] && from="-AllowFrom '$HOMELAB_LAN_CIDR'"
  # Windows' sshd hands this line to PowerShell; Bypass because client Windows refuses unsigned .ps1.
  ssh "$HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File lan-ingress.ps1 $from $1"
}
[[ -f $INV ]] || { echo "No $INV: run homelab/mac/wsl-up.sh --ansible first" >&2; exit 1; }
cd "$LAB"

case $MODE in
  --uninstall)
    windows -Uninstall
    ansible -i "$INV" homelab -b -m ansible.builtin.systemd_service -a 'name=haproxy state=stopped enabled=false'
    echo "Removed: both firewall rules; haproxy stopped and disabled (package left installed and held)." ;;
  *)
    [[ $MODE == --ansible ]] || windows ""
    [[ $MODE == --windows ]] || ansible-playbook -i "$INV" playbooks/homelab.yml --tags lan_ingress -e homelab_lan_ingress=true ;;
esac
