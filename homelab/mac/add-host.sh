#!/usr/bin/env bash
# Step 2, on the Mac: turn the HANDOFF block into `ssh <alias>`.
#
#   homelab/mac/add-host.sh homelab-1 192.168.1.50 valentin
#
# Writes one Host block to ~/.ssh/config.d/homelab (included from
# ~/.ssh/config), then connects once. ssh shows the host key: compare it with
# the handoff's "host key" line before answering yes.
set -euo pipefail
ALIAS=${1:?usage: add-host.sh <alias> <ip> <windows-user>}
IP=${2:?usage: add-host.sh <alias> <ip> <windows-user>}
USER_=${3:?usage: add-host.sh <alias> <ip> <windows-user>}
KEY="${HOMELAB_KEY:-$HOME/.ssh/homelab_ed25519}"
[[ $ALIAS =~ ^[A-Za-z0-9-]+$ ]] || { echo "alias: letters, digits, hyphens" >&2; exit 1; }
[[ $IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "ip: an IPv4 address" >&2; exit 1; }
[[ -f $KEY ]] || { echo "no $KEY -- run homelab/mac/prepare.sh first" >&2; exit 1; }

mkdir -p ~/.ssh/config.d && chmod 700 ~/.ssh/config.d
CONF=~/.ssh/config.d/homelab
touch "$CONF" && chmod 600 "$CONF"
# Include must be at the TOP of ~/.ssh/config to apply to every host.
if ! grep -qs '^Include config.d/\*' ~/.ssh/config; then
  { echo 'Include config.d/*'; echo; cat ~/.ssh/config 2>/dev/null || true; } > ~/.ssh/config.tmp
  mv ~/.ssh/config.tmp ~/.ssh/config && chmod 600 ~/.ssh/config
fi
# Replace this alias's block if it exists, keep the others.
awk -v a="$ALIAS" '$1=="Host"{skip=($2==a)} !skip' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
cat >> "$CONF" <<EOF
Host $ALIAS
  HostName $IP
  User $USER_
  IdentityFile $KEY
  IdentitiesOnly yes
  ServerAliveInterval 30
EOF
echo "added $ALIAS to $CONF"
echo "connecting -- compare the host key with the handoff block before typing yes:"
ssh -o StrictHostKeyChecking=ask "$ALIAS" 'hostname; whoami; (Get-CimInstance Win32_OperatingSystem).Caption'
