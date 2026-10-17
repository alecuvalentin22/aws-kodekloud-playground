#!/usr/bin/env bash
# Put the heavy part of the lab to sleep, wake it, or ask how it is. Runs
# `homelab-power` in WSL (installed by roles/homelab, --tags power).
#
#   homelab/mac/lab.sh status
#   homelab/mac/lab.sh sleep      # kind playground + static agent + the RKE2 VMs stop; WSL, SSH, HAProxy stay up
#   homelab/mac/lab.sh wake       # starts them again and waits for the nodes (up to 10 min); apps need ~12-20 min more
#
# Extra arguments go to homelab-power, e.g. `lab.sh idle-check --dry-run`.
# `lab` has passwordless sudo in WSL (wsl-setup.ps1), and homelab-power re-runs itself
# with sudo, so no password and no sudoers entry of its own.
set -euo pipefail
case "${1:-}" in
  sleep | wake | status | idle-check) ;;
  *) echo "usage: ${0##*/} sleep | wake | status | idle-check [--dry-run]" >&2; exit 2 ;;
esac
WSL="${HOMELAB_SSH:-homelab-1}-wsl"
# -n: never swallow stdin. Keepalives: a wake can sit silent for minutes.
exec ssh -n -o BatchMode=yes -o ServerAliveInterval=30 "$WSL" homelab-power "$@"
