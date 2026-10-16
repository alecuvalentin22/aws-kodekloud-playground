#Requires -Version 5.1
<#
.SYNOPSIS
  Step 2 of the home lab, run FROM THE MAC over SSH after bootstrap.ps1:
  Ubuntu 24.04 in WSL2, sized for VMs, reachable by Ansible, up at boot.
.DESCRIPTION
  homelab/mac/wsl-up.sh copies this file over and runs it; you do not need to
  touch the Windows desktop. Idempotent: a second run changes nothing that is
  already right.

    1. %UserProfile%\.wslconfig: memory, processors, mirrored networking,
       nested virtualization (for KVM inside WSL), no idle shutdown.
    2. Ubuntu-24.04 installed with --no-launch --web-download (no Store, no
       first-run prompt).
    3. As root inside it, with no interactive shell (so the first-run user
       prompt never fires): a Linux user, passwordless sudo for Ansible, your
       key, systemd on, and sshd on port 2222 (Windows' own sshd owns 22, and
       mirrored mode shares ports between Windows and WSL).
    4. A scheduled task that starts WSL at boot, logged on or not.

  Every claim above that depends on Windows behaviour is from Microsoft's
  docs; none of it has been run on a real PC by the author. See README.md
  "What is verified".
.PARAMETER AuthorizedKey
  The Mac's PUBLIC key -- the same line you gave bootstrap.ps1.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$AuthorizedKey,
  [string]$LinuxUser  = 'lab',
  [string]$Distro     = 'Ubuntu-24.04',
  [int]   $MemoryGB   = 48,
  [int]   $Processors = 0,          # 0 = all logical processors minus 4 for Windows
  [int]   $SshPort    = 2222
)
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'                 # wsl.exe prints UTF-16 otherwise
function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    ok  $m" -ForegroundColor Green }
function Wsl([string[]]$a) { $out = & wsl.exe @a 2>&1; if ($LASTEXITCODE -ne 0) { throw "wsl $($a -join ' ') failed: $out" }; ($out | Out-String) -replace "`0", '' }

$AuthorizedKey = $AuthorizedKey.Trim()
if ($AuthorizedKey -notmatch '^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/=]+( .*)?$') { throw 'Pass ONE OpenSSH public key line.' }
# The key is placed inside single quotes in the shell script below.
if ($AuthorizedKey.Contains("'")) { throw 'The key comment contains a single quote; remove it.' }
if ($LinuxUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw "Not a valid Linux user name: $LinuxUser" }

# --- 1. .wslconfig ---------------------------------------------------------------
Step '.wslconfig'
if ($Processors -le 0) { $Processors = [math]::Max(2, [Environment]::ProcessorCount - 4) }
$cfgPath = Join-Path $env:USERPROFILE '.wslconfig'
$want = @"
# Written by homelab/windows/wsl-setup.ps1. Keys: learn.microsoft.com/windows/wsl/wsl-config
[wsl2]
memory=${MemoryGB}GB
processors=$Processors
# Windows 11 22H2+: WSL shares Windows' network interfaces, so 127.0.0.1 works
# both ways and the LAN can reach WSL (behind the Hyper-V firewall).
networkingMode=mirrored
# Windows 11 only; default true. Required for /dev/kvm inside WSL.
nestedVirtualization=true

[general]
# -1 = never shut the distro down when idle (default 15000 ms). A lab that
# stops itself 15 s after you disconnect is not a server.
instanceIdleTimeout=-1
"@
$have = if (Test-Path $cfgPath) { Get-Content $cfgPath -Raw } else { '' }
if ($have -ne $want) {
  if ($have) { Copy-Item $cfgPath "$cfgPath.bak-$(Get-Date -Format yyyyMMddHHmmss)" }
  Set-Content -Path $cfgPath -Value $want -Encoding ascii -NoNewline
  $wslconfigChanged = $true
  Ok "written ($MemoryGB GB, $Processors CPUs); previous copy kept as .bak-*"
} else { Ok 'already as wanted' }

# --- 2. the distribution -------------------------------------------------------------
Step "$Distro"
$installed = (Wsl @('--list', '--quiet')) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($installed -notcontains $Distro) {
  Wsl @('--install', $Distro, '--no-launch', '--web-download') | Out-Null
  Ok 'installed (not launched: no first-run prompt)'
} else { Ok 'already installed' }

# --- 3. inside, as root, non-interactively ---------------------------------------------
Step "user '$LinuxUser', sudo, key, systemd, sshd :$SshPort"
$inside = @"
set -eu
id -u $LinuxUser >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo $LinuxUser
printf '%s ALL=(ALL) NOPASSWD:ALL\n' $LinuxUser > /etc/sudoers.d/90-homelab && chmod 440 /etc/sudoers.d/90-homelab
install -d -m 700 -o $LinuxUser -g $LinuxUser /home/$LinuxUser/.ssh
grep -qxF '$AuthorizedKey' /home/$LinuxUser/.ssh/authorized_keys 2>/dev/null || echo '$AuthorizedKey' >> /home/$LinuxUser/.ssh/authorized_keys
chown $LinuxUser`:$LinuxUser /home/$LinuxUser/.ssh/authorized_keys && chmod 600 /home/$LinuxUser/.ssh/authorized_keys
printf '[boot]\nsystemd=true\n\n[user]\ndefault=%s\n' $LinuxUser > /etc/wsl.conf
command -v sshd >/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends openssh-server python3 >/dev/null; }
printf '# Managed by Ansible (roles/playground). Keys only.\nPort %s\nListenAddress 127.0.0.1\nPubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' $SshPort > /etc/ssh/sshd_config.d/10-playground.conf
echo inside-ok
"@ -replace "`r", ''
$r = Wsl @('-d', $Distro, '-u', 'root', '--', 'bash', '-c', $inside)
if ($r -notmatch 'inside-ok') { throw "setup inside $Distro failed: $r" }
Ok 'done'

# --- 4. restart WSL so .wslconfig + systemd take effect --------------------------------
Step 'restart WSL'
Wsl @('--shutdown') | Out-Null
Start-Sleep -Seconds 3
$state = Wsl @('-d', $Distro, '-u', 'root', '--', 'sh', '-c', 'sleep 5; systemctl is-system-running || true')
Ok "systemd: $($state.Trim())"

# --- 5. start at boot, logged on or not ---------------------------------------------------
# S4U = "Run whether user is logged on or not" without storing a password.
Step 'scheduled task: WSL at startup'
$taskName = 'Homelab-WSL'
$action   = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument "-d $Distro --exec /bin/sh -c `"exec sleep infinity`""
$trigger  = New-ScheduledTaskTrigger -AtStartup
$who      = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$princ    = New-ScheduledTaskPrincipal -UserId $who -LogonType S4U -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 `
              -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $princ `
  -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Ok "$taskName registered for $who and started"

# --- 6. report ------------------------------------------------------------------------------
Step 'checks'
$kvm = Wsl @('-d', $Distro, '-u', 'root', '--', 'sh', '-c', 'test -e /dev/kvm && echo present || echo ABSENT')
$ssh = Wsl @('-d', $Distro, '-u', 'root', '--', 'sh', '-c', "systemctl daemon-reload; systemctl restart ssh.socket 2>/dev/null; systemctl restart ssh; ss -ltn | grep -q ':$SshPort ' && echo listening || echo NOT-LISTENING")
Write-Host "    /dev/kvm : $($kvm.Trim())"
Write-Host "    sshd :$SshPort : $($ssh.Trim())"
if ($kvm -match 'ABSENT') {
  Write-Warning 'No /dev/kvm: VMs will not run. The kind playground still will. See README.md "No KVM in WSL".'
}
Write-Host "`nNext, on the Mac:  homelab/mac/wsl-up.sh --ansible" -ForegroundColor Cyan
