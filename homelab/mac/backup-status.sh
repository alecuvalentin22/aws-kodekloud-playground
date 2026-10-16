#!/usr/bin/env bash
# How old is each backup copy? Read-only.
#
#   homelab/mac/backup-status.sh
#
# Three places an etcd snapshot lives (roles/rke2_cluster + roles/homelab
# tasks/backups.yml), newest first per place, with its age.
set -euo pipefail
WSL="${HOMELAB_SSH:-homelab-1}-wsl"
ssh -n -o BatchMode=yes "$WSL" '
  now=$(date +%s)
  age() { echo $(( (now - $1) / 3600 ))h$(( (now - $1) % 3600 / 60 ))m; }
  newest() {  # newest() <label> <list of "epoch name">
    local label=$1; shift
    if [ -z "$*" ]; then printf "%-34s %s\n" "$label" "NONE"; return; fi
    set -- $*; printf "%-34s %-48s %s old  (%s file(s))\n" "$label" "$2" "$(age "$1")" "$(( $# / 2 ))"
  }
  newest "on the VM (rke2-s1)" "$(incus exec rke2-s1 -- sh -c "cd /var/lib/rancher/rke2/server/db/snapshots 2>/dev/null && for f in *; do [ -e \"\$f\" ] && echo \$(stat -c %Y \"\$f\") \$f; done" | sort -rn | tr "\n" " ")"
  newest "in WSL (~/backups/etcd)" "$(cd ~/backups/etcd 2>/dev/null && for f in *; do [ -e "$f" ] && echo $(stat -c %Y "$f") $f; done | sort -rn | tr "\n" " ")"
  newest "on Windows (C:\\homelab-backups)" "$(cd /mnt/c/homelab-backups/etcd 2>/dev/null && for f in *; do [ -e "$f" ] && echo $(stat -c %Y "$f") $f; done | sort -rn | tr "\n" " ")"
  echo
  systemctl list-timers homelab-backup-etcd.timer --no-pager --no-legend | awk "{print \"next copy:\", \$1, \$2, \$3}"
  systemctl is-failed --quiet homelab-backup-etcd.service && echo "LAST COPY FAILED: sudo journalctl -u homelab-backup-etcd.service -n 20" || echo "last copy: ok"
'
