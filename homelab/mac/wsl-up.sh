#!/usr/bin/env bash
# Run on the Mac AFTER bootstrap.ps1, once `ssh homelab-1` works.
#
#   homelab/mac/wsl-up.sh             step 2: WSL + Ubuntu on the PC (wsl-setup.ps1 over SSH)
#   homelab/mac/wsl-up.sh --ansible   step 3: Ansible: Docker, tools, KVM check, Incus
#
# HOMELAB_SSH   ssh alias of the Windows PC     (default: homelab-1, as in add-host.sh)
# HOMELAB_KEY   the public key to authorise     (default: ~/.ssh/id_ed25519.pub)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$(cd "$HERE/.." && pwd)"
HOST="${HOMELAB_SSH:-homelab-1}"
KEYFILE="${HOMELAB_KEY:-$HOME/.ssh/id_ed25519.pub}"
[[ -f $KEYFILE ]] || { echo "No public key at $KEYFILE (set HOMELAB_KEY)" >&2; exit 1; }
KEY="$(head -1 "$KEYFILE")"
[[ $KEY == *PRIVATE* ]] && { echo "$KEYFILE is a private key" >&2; exit 1; }

if [[ ${1:-} != --ansible ]]; then
  ssh -o BatchMode=yes "$HOST" 'exit 0' || { echo "ssh $HOST does not work yet: run bootstrap.ps1 first (README step 1)" >&2; exit 1; }
  scp -q "$HERE/windows/wsl-setup.ps1" "$HOST:wsl-setup.ps1"
  # Windows' sshd hands this line to PowerShell (bootstrap.ps1 made it the
  # default shell). -ExecutionPolicy Bypass: client Windows defaults to
  # Restricted, which refuses every .ps1.
  ssh -t "$HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File wsl-setup.ps1 -AuthorizedKey '$KEY'"
  exit 0
fi

INV="$HERE/inventory.ini"
[[ -f $INV ]] || { cp "$HERE/inventory.ini.example" "$INV"; echo "created $INV from the example"; }
cd "$LAB"
ansible -i "$INV" homelab -m ansible.builtin.ping
ansible-playbook -i "$INV" playbooks/homelab.yml \
  -e "{\"playground_ssh_authorized_keys\": [\"$KEY\"], \"homelab_incus_trust_client\": \"mac\"}"
echo
echo "Next: VMs for Kubernetes --"
echo "  ansible-playbook -i $INV playbooks/homelab-vms.yml -e '{\"homelab_vm_ssh_keys\": [\"$KEY\"]}'"
