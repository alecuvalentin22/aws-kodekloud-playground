# Home lab on/off from the Mac. Source it from ~/.zshrc:
#   [[ -r ~/gcp/platform-lab/homelab/mac/lab-functions.zsh ]] && source ~/gcp/platform-lab/homelab/mac/lab-functions.zsh
#
#   lab-stop     stop the lab UNTIL lab-start: VMs + kind playground down, and nothing
#                brings them back by itself (wake/idle/sleep timers off, boot hook off,
#                VM autostart off, a "held" marker on the box)
#   lab-start    undo all of that and wake it (cluster ~3 min, web tools ~15-20 min)
#   lab-status   asleep or awake, held or not, next timers
#
# Windows and WSL stay on in both states, so SSH (and therefore lab-start) always works.
# Re-running the Ansible role (`--tags power`) also re-enables the timers and autostart.

_lab_host=homelab-1-wsl
_lab_vms='rke2-s1 rke2-a1 rke2-a2'
_lab_units='homelab-wake.timer homelab-sleep.timer homelab-idle.timer homelab-power-boot.service'

_lab_ssh() { ssh -o ConnectTimeout=10 -o BatchMode=yes "$_lab_host" "$@"; }

lab-stop() {
  print -P "%F{cyan}Stopping the home lab until lab-start...%f"
  _lab_ssh "set -e
    sudo systemctl disable --now $_lab_units >/dev/null 2>&1 || true
    for v in $_lab_vms; do sudo incus config set \"\$v\" boot.autostart false; done
    sudo mkdir -p /var/lib/homelab-power
    echo \"held since \$(date '+%F %H:%M %Z') by lab-stop\" | sudo tee /var/lib/homelab-power/hold >/dev/null
    homelab-power sleep" || { print -P "%F{red}lab-stop failed (is the PC on and on the home Wi-Fi?)%f"; return 1; }
  print -P "%F{green}Lab stopped and held. Start it again with: lab-start%f"
}

lab-start() {
  print -P "%F{cyan}Starting the home lab...%f"
  _lab_ssh "set -e
    for v in $_lab_vms; do sudo incus config set \"\$v\" boot.autostart true; done
    sudo rm -f /var/lib/homelab-power/hold
    sudo systemctl enable $_lab_units >/dev/null 2>&1
    sudo systemctl start homelab-wake.timer homelab-sleep.timer homelab-idle.timer
    homelab-power wake" || { print -P "%F{red}lab-start failed (is the PC on and on the home Wi-Fi?)%f"; return 1; }
  print -P "%F{green}Cluster is up. Web tools need ~15-20 min more (Artifactory last):%f http://home.192.168.0.23.nip.io"
}

lab-status() {
  _lab_ssh 'homelab-power status 2>&1 | head -12
    if [ -f /var/lib/homelab-power/hold ]; then echo "HELD: $(cat /var/lib/homelab-power/hold)  (lab-start to release)"; else echo "not held: night/idle timers active"; fi
    systemctl list-timers "homelab-*" --no-pager --no-legend 2>/dev/null | awk "{print \"  next: \" \$0}" | head -4' \
    || print -P "%F{red}cannot reach $_lab_host (PC off, or not on the home Wi-Fi?)%f"
}
