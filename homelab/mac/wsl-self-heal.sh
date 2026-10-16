#!/usr/bin/env bash
# Make WSL on the home-lab PC come back by itself: the `Homelab-WSL` scheduled task
# gets a 5-minute repetition (for ever) next to its boot trigger.
#
#   homelab/mac/wsl-self-heal.sh           update the task on the PC, then show its triggers and settings
#   homelab/mac/wsl-self-heal.sh --prove   DISRUPTIVE: one deliberate `wsl --shutdown`, time the recovery
#
# Why: the task used to run only at boot. If WSL stopped later (`wsl --shutdown`, a WSL
# update, a crash, an outage) nothing started it again until the next reboot. Now:
#   - triggers : at startup (unchanged) + "once, repeating every 5 minutes with no end";
#   - settings : MultipleInstances IgnoreNew (a still-running instance makes every repeat a
#                no-op, so nothing piles up), no time limit, 3 restarts 1 minute apart if a
#                run fails, StartWhenAvailable.
# Normal mode copies the current windows/wsl-setup.ps1 to the PC and runs ONLY its
# `-TaskOnly` part: .wslconfig, the WSL package, the distro and WSL itself are not touched,
# and a task instance that is already running is not restarted. Safe while the lab is up.
# The same registration is in wsl-setup.ps1, so a new PC gets it from wsl-up.sh.
#
# --prove  (labelled again at the prompt) runs `wsl --shutdown` on the PC: EVERY distro stops,
#          which takes down the Incus VMs, so the RKE2 cluster, Argo CD, Jenkins, Grafana,
#          the kind playground and Docker are gone until WSL is back (the task: about 1 to
#          5 minutes) and the VMs are started again (Incus autostart: see the list printed
#          at the end). It prints how many seconds the distro took to be Running again,
#          then how long until `ssh homelab-1-wsl` answers.
#
# HOMELAB_SSH   ssh alias of the Windows PC   (default: homelab-1; the WSL alias is <it>-wsl)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${HOMELAB_SSH:-homelab-1}"
WSLHOST="$HOST-wsl"
PS_RUN="powershell -NoProfile -ExecutionPolicy Bypass -File wsl-setup.ps1"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)

PROVE=0
case "${1:-}" in
  "") ;;
  --prove) PROVE=1 ;;
  -h|--help) sed -n '5,6p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "wsl-self-heal.sh: unknown argument '$1'" >&2; sed -n '5,6p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { sed -n '5,6p' "${BASH_SOURCE[0]}" >&2; exit 2; }

ssh "${SSH_OPTS[@]}" "$HOST" 'exit 0' || { echo "ssh $HOST does not work: see homelab/README.md step 0" >&2; exit 1; }
scp -q "${SSH_OPTS[@]}" "$HERE/windows/wsl-setup.ps1" "$HOST:wsl-setup.ps1"

if [[ $PROVE -eq 0 ]]; then
  echo "==> $HOST: registering the task (wsl-setup.ps1 -TaskOnly)"
  ssh "${SSH_OPTS[@]}" "$HOST" "$PS_RUN -TaskOnly"
  echo
  echo "Look for: two triggers (BootTrigger; TimeTrigger with Repetition Interval PT5M and NO Duration),"
  echo "MultipleInstancesPolicy IgnoreNew, RestartOnFailure Count 3. To measure the recovery: $0 --prove"
  exit 0
fi

# --- --prove -------------------------------------------------------------------------------------
cat <<EOF
*** DISRUPTIVE ***
This runs 'wsl --shutdown' on $HOST right now. Everything inside WSL stops: the Incus VMs
(rke2-s1, rke2-a1, rke2-a2, so the Kubernetes cluster and everything on it), Docker and the
kind playground. The Homelab-WSL task should start WSL again by itself; this script times it.
Nothing is lost on disk, but expect the lab to be down for several minutes.
EOF
read -r -p "Shut WSL down on $HOST now? [y/N] " ans
[[ $ans == y || $ans == Y ]] || { echo "aborted, nothing changed."; exit 0; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
T0=$(date +%s)
echo "==> $HOST: wsl --shutdown, then waiting for the task to bring the distro back"
ssh "${SSH_OPTS[@]}" "$HOST" "$PS_RUN -ProveRecovery" 2>&1 | tee "$TMP" || true
SECS="$(sed -n 's/^RECOVERY_SECONDS=//p' "$TMP" | tail -1 | tr -d '\r')"
if [[ -z $SECS || $SECS == FAILED* ]]; then
  echo
  echo "RESULT: the distro did NOT come back by itself within 15 minutes (${SECS:-no result}). Check on the PC:" >&2
  echo "  ssh $HOST 'schtasks /query /tn Homelab-WSL /v /fo list'" >&2
  exit 1
fi
T1=$(date +%s)
echo
echo "==> waiting for ssh $WSLHOST"
ok=0
for _ in $(seq 1 100); do
  if ssh "${SSH_OPTS[@]}" "$WSLHOST" 'exit 0' 2>/dev/null; then ok=1; break; fi
  sleep 3
done
T2=$(date +%s)
echo
echo "RESULT: WSL Running again $SECS s after the shutdown (task-driven)."
if [[ $ok -eq 1 ]]; then
  echo "        ssh $WSLHOST answers $((T2 - T1)) s after that ($((T2 - T0)) s in total from the start of this run)."
else
  echo "        ssh $WSLHOST still does not answer after $((T2 - T1)) s: sshd / systemd inside WSL need a look." >&2
fi
if [[ $ok -eq 1 ]]; then
  echo
  echo "Incus VMs now (they only come back by themselves if boot.autostart is set):"
  ssh "${SSH_OPTS[@]}" "$WSLHOST" 'incus list -c ns4 --format csv 2>&1 | sed "s/^/    /"' || true
fi
