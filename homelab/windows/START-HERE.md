# Windows PC → home lab: start here

You need nothing installed. PowerShell is part of Windows.

**1. Open PowerShell as administrator:** press the Windows key, type
`PowerShell`, right-click **Windows PowerShell** → **Run as administrator** →
Yes.

**2. Paste these three blocks, one at a time** (the copy button is at the
right of each block; right-click in PowerShell pastes).

Download the script, pinned to a reviewed commit:

```powershell
cd $HOME; Invoke-WebRequest 'https://raw.githubusercontent.com/alecuvalentin22/aws-kodekloud-playground/ff11a2096612b65b8aa3d34341091f4a9c6d0bc2/homelab/windows/bootstrap.ps1' -OutFile bootstrap.ps1
```

Check it is exactly that file. This must print **True**. If it prints False, stop.

```powershell
(Get-FileHash .\bootstrap.ps1 -Algorithm SHA256).Hash -eq '008198CE66D615784BA08DE9E88149FA6F5B6D9E46F8A385A7CFA83E1C6F7974'
```

Run it. The key below is the Mac's *public* key (safe to publish; it only
lets the matching private key in, and that never leaves the Mac):

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -AuthorizedKey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB59Ce0gTqMgTEnnjc0qWR3gopuftZKQfrxExnTQfBMA homelab@Valentins-MacBook-Air' -NewHostName 'homelab-1'
```

**3. Send the yellow HANDOFF block to the Mac side.** It is also saved on the
Desktop as `homelab-handoff-homelab-1.txt`. Then reboot the PC once.

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
