#!/usr/bin/env bash
# Join the home lab from a Mac: SSH set up, nothing installed.
#
#   curl -fsSL -o join.sh https://raw.githubusercontent.com/alecuvalentin22/aws-kodekloud-playground/feat/playground/homelab/mac/join.sh
#   bash join.sh                      # uses ~/.ssh/id_ed25519
#   bash join.sh ~/.ssh/other_key     # another private key
#
# For someone whose PUBLIC key the lab owner already added
# (homelab/mac/authorize-key.sh). Everything runs on the lab; this Mac only
# needs ssh and a browser, both built in. The script:
#   - writes ~/.ssh/config.d/homelab-join (two hosts: homelab-1 = the Windows PC,
#     homelab-1-wsl = the Ubuntu box where the drills run) and puts
#     `Include config.d/*` at the top of ~/.ssh/config (backed up first);
#   - pins the lab's two host keys in ~/.ssh/known_hosts.homelab, so ssh never
#     asks "are you sure you want to continue connecting?" and refuses a
#     machine that is not the lab;
#   - checks the connection and prints where everything is.
# It does not install anything, change any other ssh setting, or send anything
# anywhere but the lab. Re-running it is safe. Undo: delete those two files and
# the Include line.
set -euo pipefail

LAB_IP=192.168.0.23
WIN_USER=alecu
# The lab's public host keys (public by design: they let ssh recognise the lab).
WIN_HOSTKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICqI1E7viG1I+qtCVxzL0CiExzKcOCddIcpiE0Q4wq5r'
WSL_HOSTKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINGuOceJP3TeYr/C5V4yd0r0WH44p5ide6ckuV/9puwp'

KEY=${1:-$HOME/.ssh/id_ed25519}
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

step "1. Your SSH key"
if [[ ! -f $KEY ]]; then
  bad "no private key at $KEY"
  echo "    The lab owner added the PUBLIC half of one of your keys. Pass the matching private key:"
  echo "    bash join.sh ~/.ssh/<name>     (the file WITHOUT .pub)"
  exit 1
fi
ok "$KEY ($(ssh-keygen -lf "$KEY" 2>/dev/null | awk '{print $2}'))"

step "2. SSH settings"
mkdir -p ~/.ssh/config.d && chmod 700 ~/.ssh ~/.ssh/config.d
printf '%s\n' "homelab-1 $WIN_HOSTKEY" "homelab-1-wsl $WSL_HOSTKEY" > ~/.ssh/known_hosts.homelab
chmod 600 ~/.ssh/known_hosts.homelab
cat > ~/.ssh/config.d/homelab-join <<EOF
# Written by homelab/mac/join.sh. Home Wi-Fi only.
Host homelab-1
  HostName $LAB_IP
  User $WIN_USER
  HostKeyAlias homelab-1
  UserKnownHostsFile $HOME/.ssh/known_hosts.homelab
  StrictHostKeyChecking yes
  IdentityFile $KEY
  IdentitiesOnly yes
  ServerAliveInterval 30
# The Ubuntu box where the drills run, reached THROUGH homelab-1.
Host homelab-1-wsl
  HostName 127.0.0.1
  Port 2222
  User lab
  ProxyJump homelab-1
  HostKeyAlias homelab-1-wsl
  UserKnownHostsFile $HOME/.ssh/known_hosts.homelab
  StrictHostKeyChecking yes
  IdentityFile $KEY
  IdentitiesOnly yes
  ServerAliveInterval 30
EOF
chmod 600 ~/.ssh/config.d/homelab-join
touch ~/.ssh/config && chmod 600 ~/.ssh/config
if ! grep -qs '^Include config.d/\*' ~/.ssh/config; then
  cp ~/.ssh/config ~/.ssh/config.bak-"$(date +%Y%m%d-%H%M%S)"
  { echo 'Include config.d/*'; echo; cat ~/.ssh/config; } > ~/.ssh/config.tmp && mv ~/.ssh/config.tmp ~/.ssh/config
  chmod 600 ~/.ssh/config
  ok "~/.ssh/config: added 'Include config.d/*' at the top (backup next to it)"
else
  ok "~/.ssh/config already includes config.d/*"
fi
ok "~/.ssh/config.d/homelab-join and ~/.ssh/known_hosts.homelab written"

step "3. Can this Mac reach the lab?"
if ! nc -z -G 3 "$LAB_IP" 22 >/dev/null 2>&1; then
  bad "nothing answers at $LAB_IP. Are you on the home Wi-Fi, and is the lab PC on?"
  echo "    (The lab is only reachable from the home network.) Fix that, then run this again."
  exit 1
fi
ok "$LAB_IP answers"
if ! out=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 homelab-1-wsl 'echo "$(whoami)@$(hostname)"' 2>&1); then
  bad "ssh homelab-1-wsl failed:"
  echo "$out" | sed 's/^/    /' | tail -5
  echo "    'Permission denied (publickey)' = the lab does not have this key yet: send the lab owner"
  echo "    $KEY.pub (the PUBLIC file; never the other one)."
  exit 1
fi
ok "logged in to the drills box as $out"
doctor=$(ssh -n -o BatchMode=yes homelab-1-wsl '~/platform-lab/playground/play doctor 2>&1' | sed 's/\x1b\[[0-9;]*m//g' || true)
if grep -q '✗ \(kind\|Gitea\|Jenkins\|registry\)' <<<"$doctor"; then
  bad "the playground on the box is not healthy:"; echo "$doctor" | sed 's/^/    /'
else
  ok "the playground on the box is healthy"
fi

step "Done. You are set up."
cat <<EOF

  Drills (terminal):     ssh homelab-1-wsl      then:  play doctor   /   play start 01
  Everything else:       http://home.$LAB_IP.nip.io      (the start page: every tool, one click)
  The guide:             https://github.com/alecuvalentin22/aws-kodekloud-playground/blob/feat/playground/playground/GUIDE.md

  Logins: admin / the shared password (ask the lab owner; it is never in the repo).
  Nothing was installed on this Mac.
EOF
