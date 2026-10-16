#!/usr/bin/env bash
# Step 1, on the Mac: make a dedicated home-lab key (once) and print exactly
# what to run on the Windows PC -- pinned to a commit, with the checksum to
# compare, so the PC runs the script you reviewed and not whatever a branch
# holds later.
#
#   homelab/mac/prepare.sh [new-hostname]
#
# Reusable: run it again for every PC; pass a different name each time.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEY="${HOMELAB_KEY:-$HOME/.ssh/homelab_ed25519}"
NAME="${1:-}"
SCRIPT=homelab/windows/bootstrap.ps1

# A DEDICATED key: revoking the PC's access never touches your other keys.
if [[ ! -f $KEY ]]; then
  ssh-keygen -q -t ed25519 -N "" -f "$KEY" -C "homelab@$(hostname -s)"
  echo "created $KEY (set a passphrase? ssh-keygen -p -f $KEY; ssh-add --apple-use-keychain $KEY)"
fi
PUB=$(cat "$KEY.pub")

# Pin to the commit that is on GitHub, never to a moving branch.
source "$HERE/versions.env"
git -C "$HERE" fetch -q origin
SHA=$(git -C "$HERE" rev-parse '@{upstream}')
git -C "$HERE" cat-file -e "$SHA:$SCRIPT" 2>/dev/null \
  || { echo "$SCRIPT is not in $SHA on GitHub yet -- commit and push it first." >&2; exit 1; }
HASH=$(git -C "$HERE" show "$SHA:$SCRIPT" | shasum -a 256 | awk '{print toupper($1)}')
URL="https://raw.githubusercontent.com/$REPO_SLUG/$SHA/$SCRIPT"

cat <<EOF

On the Windows PC: Start -> type "PowerShell" -> right-click -> Run as administrator,
then paste these lines one block at a time.

  # 1. download (pinned to commit ${SHA:0:12})
  cd \$HOME; Invoke-WebRequest '$URL' -OutFile bootstrap.ps1

  # 2. this must print True -- if False, STOP: the file is not the one you reviewed
  (Get-FileHash .\\bootstrap.ps1 -Algorithm SHA256).Hash -eq '$HASH'

  # 3. run it
  powershell -ExecutionPolicy Bypass -File .\\bootstrap.ps1 -AuthorizedKey '$PUB'${NAME:+ -NewHostName '$NAME'}

At the end it prints a HOMELAB HANDOFF block (also saved to the Desktop).
Then, back here:  homelab/mac/add-host.sh <alias> <ip> <user>   (the block prints the exact line)
EOF
