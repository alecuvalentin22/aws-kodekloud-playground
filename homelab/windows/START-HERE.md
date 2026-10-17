# Windows PC → home lab: start here

You need nothing installed. PowerShell is part of Windows.

**1. Open PowerShell as administrator:** press the Windows key, type
`PowerShell`, right-click **Windows PowerShell** → **Run as administrator** →
Yes.

**2. Paste these three blocks, one at a time** (the copy button is at the
right of each block; right-click in PowerShell pastes).

Download the script, pinned to a reviewed commit:

```powershell
cd $HOME; Invoke-WebRequest 'https://raw.githubusercontent.com/alecuvalentin22/aws-kodekloud-playground/e1159b7642425f034c434bc1f95212cb52ebc181/homelab/windows/bootstrap.ps1' -OutFile bootstrap.ps1
```

Check it is exactly that file. This must print **True**. If it prints False, stop.

```powershell
(Get-FileHash .\bootstrap.ps1 -Algorithm SHA256).Hash -eq '75C1ADF3BDC7CDA5ED9D06982381CBA37E16A6C8971A3C12340AC1637AD596C2'
```

Run it. The key below is the Mac's *public* key (safe to publish; it only
lets the matching private key in, and that never leaves the Mac):

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -AuthorizedKey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB59Ce0gTqMgTEnnjc0qWR3gopuftZKQfrxExnTQfBMA homelab@Valentins-MacBook-Air' -NewHostName 'homelab-1'
```

**3. Send the yellow HANDOFF block to the Mac side.** It is also saved on the
Desktop as `homelab-handoff-homelab-1.txt`. Then reboot the PC once.

### No yellow block? (red "WSL installation appears to be corrupted" at the end)

That was a bug in the first version of the script, at the very last step:
the SSH setup itself had already finished. Paste this in the same admin
PowerShell and send the output to the Mac side instead, then reboot:

```powershell
$r=Get-NetRoute -DestinationPrefix '0.0.0.0/0'|Sort-Object RouteMetric|Select-Object -First 1; $ip=Get-NetIPAddress -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4|Select-Object -First 1; "user=$env:USERNAME ip=$($ip.IPAddress)/$($ip.PrefixLength) mac=$((Get-NetAdapter -InterfaceIndex $r.InterfaceIndex).MacAddress)"; & "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -lf "$env:ProgramData\ssh\ssh_host_ed25519_key.pub"; Get-Service sshd|Select-Object Status,StartType; Get-NetFirewallRule -Name Homelab-SSH-LAN-In|Select-Object Enabled,Profile
```

## What that did

- Windows' built-in OpenSSH Server: on at boot, **key-only** (passwords off).
- SSH allowed **only from your home network's subnet**, only while the PC is
  on a network marked Private. On public Wi-Fi it is closed.
- PowerShell as the SSH shell; never sleeps on AC power; WSL2 enabled;
  PC renamed `homelab-1` (after the reboot).
- Nothing else: no Remote Desktop, no new users, no secrets stored.

To undo all of it: same admin PowerShell,
`powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Uninstall`.

## A second PC

On the Mac: `homelab/mac/prepare.sh homelab-2` prints the same three blocks
with the new name. (This page is for `homelab-1` and this Mac's key.)

## New router? (the Mac can no longer reach the PC)

The firewall only lets in the old network's addresses, and Windows treats the
new network as Public, so the fix has to happen on the PC. Admin PowerShell
again, three blocks:

```powershell
cd $HOME; Invoke-WebRequest 'https://raw.githubusercontent.com/alecuvalentin22/aws-kodekloud-playground/0afb52aca2d1234c3f11f3fdac3f87d2ac44dc97/homelab/windows/readdress.ps1' -OutFile readdress.ps1
```

This must print **True**. If it prints False, stop.

```powershell
(Get-FileHash .\readdress.ps1 -Algorithm SHA256).Hash -eq '70BF2BDC29AFF69808B744B99296FBAB02139AECFC741258CBD91B8509ACBCAD'
```

```powershell
powershell -ExecutionPolicy Bypass -File .\readdress.ps1
```

It marks the network Private, points the three home-lab firewall rules at the
new network (same ports, nothing new opened), and prints a yellow HANDOFF
block with the new IP and MAC. On the Mac: `homelab/mac/readdress.sh <new ip>`
moves everything else (web addresses, API certificate, kubeconfig, SSH config).
Then reserve that IP for that MAC on the router so it does not move again.
