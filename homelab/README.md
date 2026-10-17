# Home lab: a Windows 11 PC you never sit at

A Windows 11 Home PC (64 GB, Intel i9) turned into an always-on lab you drive
from the Mac: WSL2 Ubuntu 24.04 with Docker (the kind [playground](../playground/))
and Incus VMs for real multi-OS Kubernetes clusters. Windows itself stays at
the minimum: an SSH server, WSL, a scheduled task, power settings.

**Win 11 Home, plainly:** there is no Hyper-V Manager and no Remote Desktop
host, and neither is needed. WSL2 runs on the Virtual Machine Platform that
Home has. The VMs live *inside* WSL, under KVM, using nested virtualization —
a Windows 11 feature (`nestedVirtualization`, default `true`). Whether
`/dev/kvm` actually appears on a given PC is the one thing to prove early;
step 3 checks it and stops with the fallback if not.

## 0. Before this page

Done once, at the PC, from [`windows/bootstrap.ps1`](windows/bootstrap.ps1)
(OpenSSH Server key-only, LAN-only firewall, never sleep on AC, WSL enabled),
with the Mac side from [`mac/prepare.sh`](mac/prepare.sh) and
[`mac/add-host.sh`](mac/add-host.sh). This page starts when, on the Mac:

```bash
ssh homelab-1 'echo ok'      # works, with your key, no password
```

Everything below runs **from the Mac**.

## 1. Ubuntu in WSL, over SSH

```bash
homelab/mac/wsl-up.sh
```

Copies [`windows/wsl-setup.ps1`](windows/wsl-setup.ps1) over and runs it. It:

- **Writes `%UserProfile%\.wslconfig`**:
  - `memory=48GB` and `processors=` all logical processors minus 4.
  - `networkingMode=mirrored`: Windows 11 22H2+. WSL shares Windows' interfaces, so `127.0.0.1` works in both directions.
  - `nestedVirtualization=true`.
  - `instanceIdleTimeout=-1` under `[general]`: never stop when idle (the default is 15 s).
  - A previous file is kept as `.bak-*`.
- **Installs `Ubuntu-24.04`** with `wsl --install … --no-launch --web-download`: no Store, no first-run prompt.
- **Configures it as root**, without an interactive shell (WSL runs the first-run user prompt only for an interactive shell):
  - creates user `lab`, with passwordless sudo for Ansible;
  - adds your key and sets `systemd=true`;
  - runs `sshd` on **2222**. Windows' own sshd owns 22, and mirrored mode shares ports.
    It listens on **127.0.0.1 only**: the one way in is `ProxyJump` through
    Windows' LAN-only, key-only sshd, so the LAN never sees port 2222. (On a
    plain Linux host, set `playground_ssh_listen: 0.0.0.0` or you lock yourself out.)
- **Registers the scheduled task `Homelab-WSL`**:
  - runs at startup, whether or not anyone is logged on (`-LogonType S4U`, no stored password);
  - command: `wsl.exe -d Ubuntu-24.04 --exec /bin/sh -c "exec sleep infinity"`;
  - **also every 5 minutes for ever** (a second, repeating trigger), `MultipleInstances IgnoreNew`, 3 restarts 1 minute apart: if WSL is stopped later, the next repeat starts it again. On a PC set up before this existed, apply it with `homelab/mac/wsl-self-heal.sh` (see "Run these yourself").
- **Prints `/dev/kvm: present | ABSENT`.**

## 2. Ansible: Docker, tools, KVM gate, Incus

```bash
homelab/mac/wsl-up.sh --ansible
```

This creates `homelab/inventory.ini` from the [example](inventory.ini.example).
Its single host is `127.0.0.1:2222`, reached through `ProxyJump=homelab-1`, so
Mac → Windows sshd → WSL sshd. It then runs `playbooks/homelab.yml`:

- **[`roles/playground`](../roles/playground/)**:
  - Docker Engine 29.8.2 (pinned and held), plus kubectl matched to the kind node, helm 3.20.0 and terraform 1.14.4, all checksum-verified.
  - Clones this repo, then sets key-only `sshd` on 2222.
  - Optional Tailscale (below).
- **[`roles/homelab`](../roles/homelab/)**:
  1. **Fails with the fallback** if `/dev/kvm` or `kvm-ok` say no.
  2. Otherwise installs **Incus 6.0.6 LTS** from Zabbly. The key is checked against its published fingerprint, and the package is pinned and held.
  3. Runs `incus admin init --preseed`:
     - storage pool `dir`;
     - bridge `incusbr0` on `10.77.0.1/24` with NAT;
     - API on `:8443`.
  4. **Prints a one-time trust token** for the Mac.

Why Zabbly, not Ubuntu's archive: noble has `incus 6.0.0`, while Zabbly's
lts-6.0 has six point releases of fixes, with QEMU bundled.

**Incus from the Mac:**

```bash
brew install incus                                    # client only
ssh -N -L 8443:127.0.0.1:8443 homelab-1 &             # nothing opened on the LAN
incus remote add homelab https://127.0.0.1:8443       # accept the fingerprint, paste the token
incus list homelab:
```

## 3. VMs and one multi-node RKE2 cluster

```bash
ansible-playbook -i homelab/inventory.ini playbooks/homelab-vms.yml \
  -e '{"homelab_vm_ssh_keys": ["'"$(cat ~/.ssh/homelab_ed25519.pub)"'"]}'
ansible-playbook -i homelab/generated/k8s.ini playbooks/rke2-cluster.yml

homelab/mac/kube-tunnel.sh                       # leave running, then elsewhere:
export KUBECONFIG=$PWD/homelab/generated/rke2.kubeconfig
kubectl get nodes
```

Three `images:ubuntu/24.04/cloud` VMs (the `/cloud` variant: the plain image
has no cloud-init), 4 vCPU / 12 GiB / 60 GiB each, on fixed addresses on the
Incus bridge: `rke2-s1` 10.77.0.31 (server), `rke2-a1` .32 and `rke2-a2` .33
(agents). cloud-init sets user `lab`, your key, passwordless sudo, no password.
Sizes and roles are `homelab_vms` in
[`roles/homelab/defaults`](../roles/homelab/defaults/main.yml).

The role only *launches missing* VMs; it does not resize existing ones, so
changing `memory` in `homelab_vms` affects new builds only (re-running reports
`changed=0` against running VMs). The three were resized 8 -> 12 GiB by hand,
one node at a time (agents first, then the server) so the cluster stayed up:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
ssh homelab-1-wsl 'incus config set <vm> limits.memory=12GiB && incus restart <vm>'
kubectl wait --for=condition=Ready node/<node> --timeout=300s && kubectl uncordon <node>
```

The root disks were grown 40 -> 60 GiB the same way (2026-10-16): the
platform's PVCs (about 40 Gi) plus several multi-GiB images did not fit
comfortably on 40 GiB nodes, and local-path does not spread volumes. Per VM,
agents first, the server last:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
ssh homelab-1-wsl 'incus config device set <vm> root size=60GiB && incus restart <vm>'
# nothing to do inside the guest: cloud-init's growpart/resizefs grow
# /dev/sda2 and the ext4 filesystem at boot (df -h / shows 58G afterwards).
kubectl wait --for=condition=Ready node/<node> --timeout=300s && kubectl uncordon <node>
```

`incus config device set ... size=` is accepted while the VM runs but the guest
only sees the new size after the restart. (`disk:` in `homelab_vms` is 60GiB so
new builds match; like `memory`, it is not applied to VMs that already exist.)

**Registry mirror.** Pods pull images through each node's own containerd, and
containerd refuses plain http. `roles/rke2_cluster` therefore writes
`/etc/rancher/rke2/registries.yaml` on every node from
`rke2_cluster_registry_mirrors` (default: the in-cluster registry at
`10.77.0.31:30500`, http). A new build gets it before the first start; to apply
a change to the running cluster:

```bash
ansible-playbook -i homelab/generated/k8s.ini playbooks/rke2-registries.yml
```

which restarts RKE2 one node at a time, agents first and the server last, and
only where the file changed (second run: `changed=0`). On the nodes RKE2 turns it
into `/var/lib/rancher/rke2/agent/etc/containerd/certs.d/10.77.0.31:30500/hosts.toml`.

[`roles/rke2_cluster`](../roles/rke2_cluster) builds ONE cluster: the server
first (token in its config before the first start), then agents that wait for
its supervisor port 9345 and join. The join token is generated once on the Mac
in `homelab/generated/rke2-token` (git-ignored, mode 600): anyone with it can
join a node, so it is a credential. The admin kubeconfig comes back to
`homelab/generated/rke2.kubeconfig` (mode 600, context `homelab-rke2`), and its
server, `https://127.0.0.1:6443`, is the Mac end of `kube-tunnel.sh` -- the
bridge is not routable from outside the PC, which is also why nothing here is
exposed to the LAN.

**iptables:** Ubuntu's cloud image does not ship it, and RKE2's CNI portmap
plugin needs it for hostPort pods (the bundled ingress-nginx). Without it
each failed attempt leaked a pod IP until a node's /24 was full and no pod
could start (seen 2026-10-16 while installing Argo CD). The VMs now get it from
cloud-init and from `roles/rke2_cluster`; the three running ones were fixed by
hand (`apt install iptables`, stop rke2, `rke2-killall.sh`, delete the leaked
`/var/lib/cni/networks/k8s-pod-network/10.42.*` files, start rke2). The new
role task has been syntax-checked, not re-run against the cluster.

`homelab/generated/k8s.ini` also keeps `[k8s]` with a `k8s_distribution` per
host, so the older single-node path (`playbooks/k8s.yml --limit <vm>`,
`roles/kubernetes`) still works against any one VM.

## 4. The kind playground, same box

```bash
ssh -t homelab-1 wsl -- bash -lc '~/platform-lab/playground/setup/up.sh'
ssh -N -L 30094:127.0.0.1:30094 -L 30095:127.0.0.1:30095 -L 30300:127.0.0.1:30300 homelab-1 &
# Jenkins http://localhost:30094  Gitea http://localhost:30300  -- on the Mac
ssh -t homelab-1 wsl -- bash -lc '~/platform-lab/playground/play start'
```

kind publishes its NodePorts on `127.0.0.1` only
([`playground/setup/kind.yaml`](../playground/setup/kind.yaml)). Use a tunnel,
as above, rather than opening them to the LAN.

## LAN access: the lab from the whole home Wi-Fi

```bash
homelab/mac/lan-ingress.sh               # Windows firewall rules, then the forwarder
curl -k --resolve argocd.127.0.0.1.nip.io:443:192.168.0.23 https://argocd.127.0.0.1.nip.io/
curl -sk https://192.168.0.23:6443/version        # RKE2 API: 401 without a client cert, which proves the path
```

**Path:** LAN client -> Windows `192.168.0.23:<port>` (shared with WSL by mirrored
networking) -> HAProxy in WSL, **layer 4, TCP passthrough** (TLS is never terminated) ->

- `80/443` -> `:80/:443` of `10.77.0.31/.32/.33` (ingress-nginx DaemonSet hostPorts);
  certificates and Host routing stay ingress-nginx's, so clients need the right Host/SNI.
- `6443` -> `:6443` of every `homelab_vms` entry with `role: server` (today `10.77.0.31`;
  a future HA control plane joins the pool by itself). The API authenticates with client
  certificates, so passthrough is enough.
- `30094/30095/30300` -> `127.0.0.1:<same port>` in WSL, where kind publishes the
  playground's NodePorts. HAProxy binds the WSL's LAN address (`192.168.0.23`) rather
  than `0.0.0.0` because a wildcard bind clashes with Docker's `127.0.0.1:30094`;
  `playground/setup/kind.yaml` (the Mac keeps its own copy) is untouched and the cluster
  is not recreated.

**Reachable from the Wi-Fi (`192.168.0.0/24`, Private network profile) and what is deliberately not:**

| Port | What | From the LAN |
|---|---|---|
| 22 | Windows sshd (`Homelab-SSH-LAN-In`, bootstrap.ps1, unchanged) | open |
| 80, 443 | Kubernetes ingress (Argo CD, Grafana, ...) | open |
| 6443 | RKE2 Kubernetes API | open (client-cert auth) |
| 30094 | Jenkins (playground) | open |
| 30095 | demo-api (playground) | open |
| 30300 | Gitea (playground) | open |
| 9345 | RKE2 supervisor / node join | **closed** (not forwarded, not in the firewall rule) |
| 2379, 2380 | etcd | **closed** |
| 10250 | kubelet | **closed** |
| 2222 | WSL sshd | **closed** (loopback + blocked by both firewalls) |
| 8443 | Incus API | **closed** (blocked by both firewalls) |
| 5001 | kind's image registry | **closed** (loopback only) |
| 8404 | HAProxy stats | **closed** (loopback only) |

Firewall: Defender rule `Homelab-LAN-Ingress-In` **and** Hyper-V firewall rule
`Homelab-LAN-Ingress-HyperV-In` (WSL VMCreatorId `{40E0AC32-...}`) allow exactly
`-Ports` (default `80,443,6443,30094,30095,30300` in
[`lan-ingress.ps1`](windows/lan-ingress.ps1)) from the PC's own LAN subnet
(auto-detected; override with `HOMELAB_LAN_CIDR`), scoped identically. The Hyper-V default
stays Block: the script does **not** set `DefaultInboundAction Allow`, which would open
every WSL listener. Keep `-Ports` in step with `homelab_lan_ingress_*` / `homelab_lan_tcp_forwards`
in [`roles/homelab/defaults`](../roles/homelab/defaults/main.yml).

**Currently open to the whole LAN** (the user's decision, 2026-10-16: "everything deployed,
like the k8s api, should be ok from wifi"): any device on the Wi-Fi can reach every
Ingress host, Jenkins, Gitea, demo-api and the Kubernetes API endpoint, so those tools' own
authentication is the only protection. To narrow it, run on the PC
`homelab/windows/lan-ingress.ps1 -AllowFrom <ip>`, for example `-AllowFrom 192.168.1.161`
for the Mac only.

**Forwarder:** HAProxy 2.8.16 from Ubuntu's noble archive, pinned and held, TCP-connect
health check on every backend every 2 s (3 fails = out, 2 passes = back), `leastconn`.
Why HAProxy, not nginx `stream`: real active health checks and a per-server UP/DOWN view
without nginx Plus. The LAN-address binds use `transparent`, so HAProxy still starts at
boot if WSL's network is not up yet. If the PC's DHCP lease changes, re-run
`homelab/mac/lan-ingress.sh --ansible` to re-render the bind address. State:
`ssh homelab-1-wsl "curl -s 'http://127.0.0.1:8404/;csv' | cut -d, -f1,2,18"`.

**Undo:**

```bash
homelab/mac/lan-ingress.sh --uninstall   # removes exactly the two rules; stops and disables haproxy
```

The `haproxy` package stays installed and held. Mirrored networking means Windows must
keep these ports free; the role refuses to start on top of another listener in WSL, and the
script warns if Windows itself listens on them. To drop only some ports, edit
`homelab_lan_tcp_forwards` and re-run with `-Ports` (without them) for the firewall.

## AWS from the box

The AWS tier of the interview game (drills 11-19, 61-69) can be played from the box.
Tools: AWS CLI v2 and `make` come from the role, `ansible-playbook -i homelab/inventory.ini playbooks/homelab.yml --tags awscli` (the CLI zip is sha256-pinned in `roles/playground/defaults`).
Credentials never go in `~/.aws`; the box reads `~/.config/platform-lab/aws-lab-creds.env`.

```bash
homelab/mac/send-aws.sh                 # owner: keys + Jenkins/Gitea logins + EKS kubeconfig (+ terraform.tfvars), then 3 checks
homelab/mac/send-aws.sh --creds-only    # a new KodeKloud session: only the keys
ssh homelab-1-wsl 'playground/setup/aws-creds.sh'   # a candidate with her own keys: pasted hidden, validated, written 600
```

The EKS API admits only the home's public IP (`public_access_cidrs`), which the box shares with the Mac.

## Another computer's SSH key

SSH is key-only and, after bootstrap, only this Mac's key gets in. To let another
computer in (from the Mac, with the `.pub` file they sent; the private half never
leaves their machine):

```bash
homelab/mac/authorize-key.sh their_id_ed25519.pub           # drills only: WSL box as `lab`, no Windows shell
homelab/mac/authorize-key.sh their_id_ed25519.pub --full    # also an administrator PowerShell on the PC
homelab/mac/authorize-key.sh their_id_ed25519.pub --remove  # take it out of both again
```

It writes the key to Windows' `administrators_authorized_keys` (permissions kept) and
to `lab`'s `authorized_keys` in WSL, and prints the `~/.ssh/config` for the other
computer plus the two host-key fingerprints to compare. "Drills only" restricts the
Windows half to `command="exit 1",restrict,port-forwarding,permitopen="127.0.0.1:2222"`:
it can only carry the connection on to WSL. Tested 2026-10-17 with a throwaway key:
drills-only gives no Windows shell (exit 1, no output), reaches WSL as `lab`, and is
refused any other port ("administratively prohibited"); `--full` gives the shell;
`--remove` locks it out of both. Home Wi-Fi only, like everything here.

## Run these yourself

Three scripts that change the running lab. They are written and statically checked
(`bash -n`, shellcheck, `ansible-playbook --syntax-check`, the PowerShell 7.4 parser) but
**not run by their author**; each one asks or refuses before it does anything that matters.

| Script | What it changes | Run |
|---|---|---|
| [`mac/lan-kube-api.sh`](mac/lan-kube-api.sh) | Adds `192.168.0.23` to `tls-san` on the RKE2 **server VM** (variable `rke2_cluster_extra_sans`, [`playbooks/rke2-sans.yml`](../playbooks/rke2-sans.yml)); `rke2-server` restarts once (API down ~1-2 min, pods keep running). Writes `generated/rke2-lan.kubeconfig` (mode 600, context `homelab-rke2-lan`) and runs `kubectl get nodes` with it: kubectl from the LAN, no tunnel. | `homelab/mac/lan-kube-api.sh` (asks y/N; `--yes` skips it; `--undo` removes the name and the file) |
| [`platform/secrets.sh`](platform/secrets.sh) | One password for user `admin` in Grafana, Jenkins, Argo CD and Artifactory: the chart Secrets, Grafana's and Artifactory's databases, Argo CD's bcrypt hash; restarts Grafana, Jenkins and `argocd-server`; deletes `argocd-initial-admin-secret`. Verifies each login over the LAN ingress and prints only HTTP codes. | `homelab/platform/secrets.sh` (`--check`, read-only, is the default)<br>`HOMELAB_ADMIN_PASSWORD='<your password>' homelab/platform/secrets.sh --apply` |
| [`mac/wsl-self-heal.sh`](mac/wsl-self-heal.sh) | Re-registers only the `Homelab-WSL` task on the PC (`wsl-setup.ps1 -TaskOnly`): boot trigger **plus** a repeat every 5 minutes. WSL itself is not touched. `--prove` does one deliberate `wsl --shutdown` (everything in WSL, including the cluster, stops) and prints the seconds until the task has WSL back. | `homelab/mac/wsl-self-heal.sh`<br>`homelab/mac/wsl-self-heal.sh --prove` (asks y/N) |

Order that works: `lan-kube-api.sh` first (then `secrets.sh` needs no tunnel), `secrets.sh --check`,
`secrets.sh --apply`, `wsl-self-heal.sh`; `--prove` last and only when you can spare the lab for a few minutes.

- **`lan-kube-api.sh`** needs the Mac on the PC's Wi-Fi/LAN and HAProxy up (`lan-ingress.sh`). Anyone on
  the LAN can reach 6443 already; the kubeconfig's client certificate is the credential, so keep the file private.
  Re-running `playbooks/rke2-cluster.yml` without the variable drops the name again; run the script again after it.
  RKE2 only adds SANs to its stored certificate; if the new name is not served after the restart, the playbook
  deletes the `rke2-serving` secret and rebuilds it (a second restart). This path has not been exercised.
- **`secrets.sh`** takes the password from the environment only (never an argument, never printed, no `set -x`;
  it reaches curl and kubectl through mode-600 temp files). Kubernetes access: `$KUBECONFIG`, else
  `generated/rke2-lan.kubeconfig` (after `lan-kube-api.sh`), else `generated/rke2.kubeconfig` with
  `homelab/mac/kube-tunnel.sh` running. Artifactory is skipped (Secret only) while it is not answering.
  `secrets.sh --selftest` checks the local parts with a dummy password and contacts nothing.
- **`wsl-self-heal.sh`** (normal mode) is safe while the lab runs. The repetition is verified by reading the task
  back (`Get-ScheduledTask`); that Windows behaviour is from Microsoft's documentation, not yet seen on the PC.

## Backups

What is backed up, and where. Check it any time with `homelab/mac/backup-status.sh`.

| Layer | How | Where it lives | Why this way |
|---|---|---|---|
| Cluster state (every object, every Secret) | RKE2 etcd snapshots, `etcd-snapshot-schedule-cron: "0 */6 * * *"`, keep 12 (`roles/rke2_cluster` defaults) | on rke2-s1: `/var/lib/rancher/rke2/server/db/snapshots` | RKE2's own mechanism; a few MB each (12 MB on 2026-10-17) |
| Off the VM | `homelab-backup-etcd.timer` in WSL (`roles/homelab` tasks/backups.yml, `--tags backups`): at 00/06/12/18:20 and 15 min after boot, `incus file pull` the new snapshots, keep 24 | WSL `~/backups/etcd` **and** `C:\homelab-backups\etcd` | a snapshot on the VM dies with the VM; the Windows copy survives a lost WSL disk |
| Manifests, config | git (this repo) + Argo CD | GitHub | the platform rebuilds from git; only state is not in git |
| PVC data (Artifactory files, Jenkins build history, Grafana edits) | **not scheduled** — take one by hand before risky changes: `incus snapshot create rke2-a2 before-<what>` | the same Incus pool | the pool's `dir` driver makes every VM snapshot a FULL disk copy (~15 GB per VM) and briefly freezes the VM, etcd included |

**The etcd snapshots contain every cluster Secret in clear text** (the shared admin
password, Argo CD's token, the RKE2 join token). On Windows the folder is
therefore locked to SYSTEM, Administrators and the WSL user. For a new PC, once:

```powershell
icacls C:\homelab-backups /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "$env:USERNAME:(OI)(CI)F" /T
```

(The copy job uses `rsync -rt`, not `-a`: under that ACL Windows refuses
Unix chmod, and NTFS permissions are what protect the copy.)

An on-demand snapshot, e.g. before an upgrade:
`ssh homelab-1-wsl 'incus exec rke2-s1 -- rke2 etcd-snapshot save --name before-<what>'`
(it prints "Unknown flag --etcd-snapshot-schedule-cron … skipping": the
`etcd-snapshot` subcommand reads the server's config file but ignores server-only
keys — harmless).

## Staying up (human-only settings on the PC)

- **Power**: `bootstrap.ps1` sets never-sleep on AC.
- **Windows Update**: Home can postpone restarts but not refuse them. Set Settings → Windows Update → Advanced options → Active hours to cover the hours you use the lab. After any restart, the `Homelab-WSL` task brings WSL back without a login, and since the 5-minute repeat it also does so after a `wsl --shutdown` or crash. That's what the checklist below proves.
- **Idle shutdown**: `instanceIdleTimeout=-1` keeps the distro up. `vmIdleTimeout` (default 60 s) only acts once no distro is running, which the task prevents.

## Optional: Tailscale (away from home)

Set `playground_tailscale_enable=true`, then run `sudo tailscale up` once in WSL.
Install it **inside WSL, not on Windows**, for three reasons:
- the tailnet node is the machine that runs the lab;
- it's automated here and comes up with systemd;
- it needs no Hyper-V firewall rule.

Do not also run Tailscale on Windows: in mirrored mode the two would share interfaces.

## Verify it is a home lab

1. Reboot the PC. Do **not** log in.
2. From the Mac: `ssh homelab-1 'wsl -l -v'` shows `Ubuntu-24.04 Running`.
3. `ansible -i homelab/inventory.ini homelab -m ping` returns `pong`.
4. `ssh homelab-1 wsl -- docker ps` lists `playground-control-plane` (once step 4 has run).
5. `incus list homelab:` shows the VMs `RUNNING`.
6. `ssh -t homelab-1 wsl -- bash -lc '~/platform-lab/playground/play doctor'` is all green.

## No KVM in WSL (the fallback)

- **VMware Workstation Pro**: free for personal **and** commercial use since 2024-11-11 (Broadcom). Install it on Windows and drive VMs with Vagrant or Packer (this repo has Packer skills). It adds one Windows program and keeps the rest of this page: the k8s inventory just points at the VMware VMs.
- **Proxmox VE**: if Windows can go, install Proxmox on the PC instead. It's a real hypervisor with a web UI and clusters, and the cleanest home lab, but Windows is gone.

## What is verified

| | How |
|---|---|
| `roles/playground` | ran in a throwaway Ubuntu 24.04 container (arm64), twice: second run **changed=0** (stopped by design at "no systemd") |
| SSH/Tailscale tasks | same container: refuses an empty key list; first run changed=7, second **changed=0**; `sshd -t` accepts the drop-in; Tailscale 1.102.5 installed |
| `roles/homelab` | same container: **KVM gate fails with the fallback message**; with the gate off: Zabbly key matches its fingerprint, Incus 6.0.6 installed and held (per-arch build stamp handled), second run **changed=0** up to the daemon start (no systemd) |
| Templates | preseed and cloud-init parse as YAML; generated inventory parses, 3 hosts in `[k8s]` with the ProxyJump chain |
| `wsl-setup.ps1` | PowerShell 7.4 parser: 0 errors |
| Docs claims | Microsoft Learn (wsl-config, WSL networking, Hyper-V firewall, OpenSSH, ScheduledTasks), Incus docs, Zabbly README, Broadcom blog, fetched 2026-10-16 |

**Not verified: the Windows-side scripts after their last edits.**
- `wsl-setup.ps1` itself was run on the real PC twice by `homelab/mac/wsl-up.sh` (2026-10-16) and installed Ubuntu; it is the edits made after those runs that are unconfirmed.
- `wsl.exe` under an S4U task and over SSH.
- The lid-close setting in `bootstrap.ps1` is parsed (PowerShell 7.4: 0 errors) but has not been run: it changes power settings, so run it yourself.
- `playbooks/k8s.yml` (the older single-node path) against the VMs: not run, only the multi-node `rke2-cluster.yml` was.

If the S4U task does not start WSL, fall back to automatic logon
(Sysinternals Autologon) plus the same task "At log on".

## Verified on real hardware: homelab-1, 2026-10-16

Windows 11 Home 10.0.26200, Intel i9-10885H (8c/16t), 64 GB, fresh install.

| Step | Result |
|---|---|
| `bootstrap.ps1` | sshd key-only, LAN-only rule, rename; the first version then crashed printing the handoff (fixed, see git log) |
| `ssh homelab-1` from the Mac | works; host key verified against the PC's screen |
| WSL features | enabled over SSH with DISM (exit 3010), then a remote reboot: back in ~70 s, nobody logged in |
| WSL itself | `wsl --update` **fails over SSH** (`Wsl/CallMsi/Install/REGDB_E_CLASSNOTREG`); the signed MSI 3.0.1 via msiexec works |
| Ubuntu 24.04.5 | installed unattended; openssh-server first failed on `0.0.0.0:22: Address already in use` (mirrored networking shares :22 with Windows) -- the drop-in now goes in first |
| `ssh homelab-1-wsl` | `lab@homelab-1`, 12 CPUs, 47 GB, systemd, passwordless sudo, sshd on 127.0.0.1:2222 only |
| `/dev/kvm` in WSL | **present**: nested virtualization works on Win 11 Home + this i9, so Incus VMs are on |
| boot without login | rebooted: WSL up 17 s after boot via the `Homelab-WSL` task, no desktop session |
| full Windows reboot (2026-10-17) | `shutdown /r`, nobody logged in afterwards. From boot: Homelab-WSL task ran **17 s**, Windows sshd + WSL ssh **~71 s**, 3 VMs RUNNING **~72 s**, 3/3 nodes Ready **106 s**; HAProxy, the LAN firewall/Hyper-V rules, incus-docker-forward and the kind playground all up unaided. URLs (200): Backstage + playground Jenkins/Gitea/demo-api **115 s**, Argo CD **135 s**, Grafana **503 s**, start page **513 s**, platform Jenkins **716 s**, Artifactory **1290 s** (~21.5 min). Budget ~12 min after a power cut for everything but Artifactory. |
| recovery drill (2026-10-17) | `wsl-self-heal.sh --prove`: deliberate `wsl --shutdown`; the 5-minute task brought WSL back **85 s** later with nobody touching it, ssh 1 s after. VMs, 3/3 nodes, the kind playground, HAProxy and the Wi-Fi URLs all came back on their own; ~12 min after the shutdown every URL answered 200 except Artifactory, which needs its usual 10–15 min first start. The VMs returned via Incus' last-state restore; `boot.autostart=true` (servers first) is now set explicitly by the role. The drill also found that the script's first `ssh` swallowed stdin, so a piped `y` silently aborted the prompt: fixed with `ssh -n`. |
| `wsl-up.sh --ansible` | first run on the real box: `ok=47 changed=28 failed=0` -- Docker 29.8.2, kubectl 1.34.11, helm 3.20.0, terraform 1.14.4, Incus 6.0.6 with `incusbr0` 10.77.0.1/24 |
| a real VM | `incus launch images:ubuntu/24.04 --vm`: up in 24 s, its own kernel 6.8.0-147, `systemd-detect-virt` = kvm, IP 10.77.0.125 |
| 3 VMs | `homelab-vms.yml`: `rke2-s1` 10.77.0.31, `rke2-a1` .32, `rke2-a2` .33, 4 vCPU / 8 GiB each (since resized to 12 GiB, see section 3). Real-hardware faults fixed in the role: plain `images:ubuntu/24.04` has no cloud-init (now `/cloud`); Docker's iptables FORWARD DROP blocked VM egress (DOCKER-USER rules + `incus-docker-forward.service`); `lock_passwd: true` made sshd refuse `lab` (UsePAM no) -- now `hashed_passwd: "*"`; the vault `group_vars` symlink broke every playbook (now opt-in); ssh offered agent keys first (`IdentitiesOnly`). Re-run: `ok=8 changed=0` |
| RKE2 cluster | `rke2-cluster.yml` first run (cold, incl. RKE2 download): 3 min 57 s, `failed=0`; 3 nodes Ready, v1.33.13+rke2r1, containerd 2.2.5-k3s1, kernel 6.8.0-147. The server node registered ~2 min before the agents did (node ages 2m56s / 62s / 56s). First run restarts `rke2-server`/`rke2-agent` once through the handlers (config written, then service started, then handler); the **second run is `changed=0` on all three nodes** |
| From the Mac | `kube-tunnel.sh` + `kubectl get nodes` with `homelab/generated/rke2.kubeconfig` (mode 600, context `homelab-rke2`): the same 3 nodes |
| It is a real cluster | Deployment, 3 replicas, `topologySpreadConstraints` (maxSkew 1 on hostname, DoNotSchedule): one pod each on `rke2-s1`, `rke2-a1`, `rke2-a2`; all Running in ~5 s; deleted afterwards, none left |

`add-host.sh` now writes both aliases per PC (`homelab-N` and
`homelab-N-wsl`). For reference, the Ubuntu-side one:

```sshconfig
Host homelab-1-wsl
  HostName 127.0.0.1
  Port 2222
  User lab
  ProxyJump homelab-1
  HostKeyAlias homelab-1-wsl
  IdentityFile ~/.ssh/homelab_ed25519
  IdentitiesOnly yes
```
