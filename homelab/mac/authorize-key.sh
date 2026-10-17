#!/usr/bin/env bash
# Let another computer's SSH key into the home lab -- from the Mac.
#
#   homelab/mac/authorize-key.sh their_id_ed25519.pub            drills only (default)
#   homelab/mac/authorize-key.sh their_id_ed25519.pub --full     also a Windows admin shell
#   homelab/mac/authorize-key.sh their_id_ed25519.pub --remove   take it out again
#
# The way in is always two hops: Windows OpenSSH (homelab-1, port 22), then the
# Ubuntu box in WSL (homelab-1-wsl, 127.0.0.1:2222, user `lab`), via ProxyJump.
#
# Default ("drills only"): on Windows the key is written with
#   command="exit 1",restrict,port-forwarding,permitopen="127.0.0.1:2222"
# so it can do exactly one thing there: carry the connection through to WSL's
# sshd. No Windows shell, no command, no other port. (`restrict` alone is not
# enough: it turns off forwarding, pty and agent, but a command still runs --
# the forced command is what takes the shell away. Tested 2026-10-17.) In WSL it is a normal key
# for `lab` (where `play`, git and kubectl run; `lab` has sudo there).
# --full drops the Windows restriction: the key then gets an administrator
# PowerShell on the PC (administrators_authorized_keys is the admins' file).
#
# Re-runnable: a key already present (matched on its key blob, not its comment)
# is replaced, so switching between default and --full is just running it again.
# Prints the ssh config and the host-key fingerprints the other computer needs.
#
# HOMELAB_SSH       Windows ssh alias        (default: homelab-1)
# HOMELAB_SSH_WSL   WSL ssh alias            (default: homelab-1-wsl)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIN="${HOMELAB_SSH:-homelab-1}"
WSL="${HOMELAB_SSH_WSL:-homelab-1-wsl}"
PUB=${1:?usage: authorize-key.sh <key.pub> [--full|--remove]}
MODE=${2:-drills}
case $MODE in drills|--full|--remove) ;; *) sed -n '2,6p' "${BASH_SOURCE[0]}" >&2; exit 2 ;; esac

[[ -r $PUB ]] || { echo "cannot read $PUB" >&2; exit 1; }
LINE=$(grep -m1 -E '^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) ' "$PUB" || true)
[[ -n $LINE ]] || { echo "$PUB: no public key line (expected 'ssh-ed25519 AAAA... comment')" >&2; exit 1; }
[[ $LINE != *PRIVATE* ]] || { echo "that is a PRIVATE key: never send or use that file; use the .pub" >&2; exit 1; }
FP=$(ssh-keygen -lf <(echo "$LINE")) || { echo "$PUB: not a valid public key" >&2; exit 1; }
read -r TYPE BLOB _ <<<"$LINE"
[[ $BLOB =~ ^[A-Za-z0-9+/]+=*$ ]] || { echo "unexpected key format" >&2; exit 1; }
ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$WIN" 'exit 0' || { echo "ssh $WIN does not work from this Mac" >&2; exit 1; }
echo "key: $FP"

case $MODE in
  drills) WINLINE="command=\"exit 1\",restrict,port-forwarding,permitopen=\"127.0.0.1:2222\" $TYPE $BLOB ${LINE#"$TYPE $BLOB"}" ;;
  --full) WINLINE="$LINE" ;;
  --remove) WINLINE="" ;;
esac
WINLINE=${WINLINE%% }
B64=$(printf '%s' "$WINLINE" | base64 | tr -d '\n')

# Windows: drop any line with this blob, then (unless --remove) add ours.
# Set-Content rewrites the existing file in place, so its ACL (SYSTEM and
# Administrators only, which sshd insists on) is kept.
ssh -n -o BatchMode=yes "$WIN" "\$f='C:\\ProgramData\\ssh\\administrators_authorized_keys'; \$keep=@(Get-Content \$f | Where-Object { \$_ -notmatch [regex]::Escape('$BLOB') }); \$new='$B64'; if (\$new) { \$keep += [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String(\$new)) }; Set-Content -Path \$f -Value \$keep -Encoding ascii; 'windows: ' + @(Get-Content \$f).Count + ' key line(s)'"

# WSL: same for lab's authorized_keys.
ADD=yes; [[ $MODE == --remove ]] && ADD=no
ssh -n -o BatchMode=yes "$WSL" "f=~/.ssh/authorized_keys; grep -vF '$BLOB' \"\$f\" > \"\$f.tmp\" || true; [ $ADD = no ] || echo '$TYPE $BLOB' >> \"\$f.tmp\"; chmod 600 \"\$f.tmp\"; mv \"\$f.tmp\" \"\$f\"; echo \"wsl: \$(wc -l < \"\$f\") key line(s)\""

if [[ $MODE == --remove ]]; then echo "removed from both."; exit 0; fi

# shellcheck source=/dev/null
source "$HERE/lan.env"
WINUSER=$(ssh -G "$WIN" | awk '$1=="user"{print $2}')
fp_win=$(ssh -n -o BatchMode=yes "$WIN" '& "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -lf "$env:ProgramData\ssh\ssh_host_ed25519_key.pub"' | tr -d '\r')
fp_wsl=$(ssh -n -o BatchMode=yes "$WSL" 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub')
cat <<EOF

Done ($([[ $MODE == --full ]] && echo "drills + Windows admin shell" || echo "drills only: no Windows shell")).
On the OTHER computer, add this to ~/.ssh/config (Windows: C:\\Users\\<you>\\.ssh\\config),
with IdentityFile pointing at the private half of the key that was sent:

Host homelab-1
  HostName $HOMELAB_LAN_IP
  User $WINUSER
  IdentityFile ~/.ssh/id_ed25519
Host homelab-1-wsl
  HostName 127.0.0.1
  Port 2222
  User lab
  ProxyJump homelab-1
  HostKeyAlias homelab-1-wsl
  IdentityFile ~/.ssh/id_ed25519

Then: ssh homelab-1-wsl   (home Wi-Fi only). It asks twice whether to trust a host
key; answer yes only if the fingerprints match:
  homelab-1      $fp_win
  homelab-1-wsl  $fp_wsl
EOF
