#Requires -Version 5.1
<#
.SYNOPSIS
  Turn a fresh Windows 11 (Home or Pro) PC into a home-lab host your Mac can
  manage over SSH -- from your local network only, with your key only.

.DESCRIPTION
  Run ONCE, in an elevated PowerShell (Run as administrator). Idempotent:
  running it again changes nothing that is already right.

  What it does, and nothing more:
    1. Installs the built-in OpenSSH Server (a Windows optional feature) and
       starts it at boot.
    2. Key-only auth: password logins are disabled; the one public key you
       pass in is the only way in, as an administrator.
    3. Firewall: SSH (TCP 22) accepted only from your local subnet, and only
       while the PC is on a network marked Private. Public Wi-Fi: closed.
    4. PowerShell as the SSH shell, so the Mac gets a real shell.
    5. Never sleeps or hibernates on AC power (it is a server now).
    6. Enables WSL2 without installing a distribution yet. The Mac does
       the rest over SSH (see homelab/README.md).

  What it does NOT do: open RDP, create users, store any secret, or touch
  anything when -Uninstall is given except what it added itself.

.PARAMETER AuthorizedKey
  The Mac's PUBLIC key, one line ("ssh-ed25519 AAAA... comment").
  homelab/mac/prepare.sh prints it for you.

.PARAMETER AllowFrom
  Who may connect, as a CIDR. Default: this PC's own LAN subnet, detected
  from the interface that holds the default route (e.g. 192.168.0.0/24).

.PARAMETER NewHostName
  Optional. Rename this PC (e.g. homelab-1) so several home-lab machines stay
  distinguishable. Takes effect after the next reboot.

.PARAMETER Uninstall
  Remove what this script added: the firewall rule, the key, sshd's
  start-at-boot, and the hardening lines. Leaves WSL alone.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -AuthorizedKey 'ssh-ed25519 AAAA... mac'
#>
[CmdletBinding()]
param(
  [string]$AuthorizedKey,
  [string]$AllowFrom,
  [string]$NewHostName,
  [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$RuleName  = 'Homelab-SSH-LAN-In'
$SshDir    = Join-Path $env:ProgramData 'ssh'
$Config    = Join-Path $SshDir 'sshd_config'
$AdminKeys = Join-Path $SshDir 'administrators_authorized_keys'
$Marker    = '# --- homelab bootstrap ---'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    ok  $msg" -ForegroundColor Green }

# --- must be elevated ---------------------------------------------------------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this in an elevated PowerShell: right-click PowerShell -> Run as administrator.'
}

# --- uninstall ------------------------------------------------------------------
if ($Uninstall) {
  Step 'Removing what bootstrap.ps1 added'
  Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  if (Test-Path $AdminKeys) { Remove-Item $AdminKeys -Force }
  if (Test-Path $Config) {
    $lines = @(Get-Content $Config)
    $s = [array]::IndexOf($lines, $Marker)
    $e = [array]::IndexOf($lines, "$Marker end")
    if ($s -ge 0 -and $e -gt $s) {
      $keep = for ($i = 0; $i -lt $lines.Count; $i++) { if ($i -lt $s -or $i -gt $e) { $lines[$i] } }
      Set-Content -Path $Config -Value $keep -Encoding ascii
    }
  }
  Stop-Service sshd -ErrorAction SilentlyContinue
  Set-Service sshd -StartupType Manual -ErrorAction SilentlyContinue
  Ok 'firewall rule, key and hardening removed; sshd stopped (the feature stays installed)'
  return
}

# --- validate input ---------------------------------------------------------------
if (-not $AuthorizedKey) { throw 'Pass -AuthorizedKey "<your Mac public key>". homelab/mac/prepare.sh prints the full command.' }
$AuthorizedKey = $AuthorizedKey.Trim()
if ($AuthorizedKey -notmatch '^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/=]+( .*)?$') {
  throw 'That does not look like ONE OpenSSH public key line. Pass the .pub contents, never the private key.'
}
if ($AuthorizedKey -match 'PRIVATE KEY') { throw 'That is a PRIVATE key. Stop, and pass the .pub file instead.' }

# The LAN interface: the one holding the default route.
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
if (-not $route) { throw 'No default route: connect this PC to your network (Wi-Fi or cable) first.' }
$LanIf = $route.InterfaceIndex
$ip = Get-NetIPAddress -InterfaceIndex $LanIf -AddressFamily IPv4 | Select-Object -First 1
if (-not $AllowFrom) {
  # Network address from IP + prefix length.
  $bytes = ([Net.IPAddress]$ip.IPAddress).GetAddressBytes(); [array]::Reverse($bytes)
  $mask  = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $ip.PrefixLength))
  $net   = [BitConverter]::GetBytes([BitConverter]::ToUInt32($bytes, 0) -band $mask); [array]::Reverse($net)
  $AllowFrom = "$([Net.IPAddress]::new($net))/$($ip.PrefixLength)"
}
if ($AllowFrom -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') { throw "-AllowFrom must be a CIDR such as 192.168.0.0/24 (got '$AllowFrom')." }
$prefix = [int]($AllowFrom.Split('/')[1])
if ($prefix -lt 16) { throw "-AllowFrom $AllowFrom is wider than a home network. Refusing; pass something like /24." }

# --- 1. OpenSSH Server --------------------------------------------------------------
Step 'OpenSSH Server (built-in Windows feature)'
$cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*' | Select-Object -First 1
if (-not $cap) { throw 'This Windows build does not offer OpenSSH.Server as a capability.' }
if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service sshd -StartupType Automatic
Start-Service sshd          # first start generates the host keys and default config
Ok "$($cap.Name) installed, sshd starts at boot"

# --- 2. key-only, admin key -------------------------------------------------------------
Step 'Key-only authentication'
# Administrators read their keys from ProgramData, not from ~\.ssh -- that is
# what the default sshd_config's "Match Group administrators" block says.
Set-Content -Path $AdminKeys -Value $AuthorizedKey -Encoding ascii
# sshd refuses the file unless only Administrators and SYSTEM can touch it.
# SIDs, not names, so this works on non-English Windows too.
icacls.exe $AdminKeys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
# sshd uses the FIRST value it reads for each keyword, so the hardening goes at
# the top of the file, inside markers that -Uninstall can find again.
$hardening = @(
  $Marker,
  'PasswordAuthentication no',
  'KbdInteractiveAuthentication no',
  'PubkeyAuthentication yes',
  'PermitEmptyPasswords no',
  "$Marker end"
)
$current = Get-Content $Config
if ([array]::IndexOf($current, $Marker) -lt 0) {
  Set-Content -Path $Config -Value ($hardening + $current) -Encoding ascii
}
Restart-Service sshd
Ok 'passwords off; one key, for administrators'

# --- 3. firewall: LAN only, Private profile only ------------------------------------------
Step "Firewall: SSH only from $AllowFrom, only on Private networks"
# The feature ships its own rule open to every address. Turn it off; ours replaces it.
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -Name $RuleName -DisplayName 'Homelab SSH (LAN only)' `
  -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow `
  -RemoteAddress $AllowFrom -Profile Private | Out-Null
# The rule only applies on Private networks, so the home network must be one.
$netProfile = Get-NetConnectionProfile -InterfaceIndex $LanIf
if ($netProfile.NetworkCategory -ne 'Private') {
  Set-NetConnectionProfile -InterfaceIndex $LanIf -NetworkCategory Private
  Ok "network '$($netProfile.Name)' set to Private (it was $($netProfile.NetworkCategory))"
}
Ok "rule $RuleName"

# --- 4. PowerShell as the SSH shell ----------------------------------------------------------
Step 'PowerShell as the default SSH shell'
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null
Ok 'DefaultShell set'

# --- 5. never sleep on AC ------------------------------------------------------------------
Step 'Power: never sleep or hibernate on AC'
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
# Laptops: closing the lid on AC must not sleep it. The setting is HIDDEN on
# some Modern Standby models (homelab-1, an i9-10885H laptop), so unhide it
# first or the change does not show anywhere. Battery (DC) stays "sleep".
if (Get-CimInstance Win32_Battery) {
  powercfg /attributes SUB_BUTTONS LIDACTION -ATTRIB_HIDE
  powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
  powercfg /setactive SCHEME_CURRENT
  Ok 'laptop: lid close on AC = do nothing'
}
Ok 'done (battery settings untouched)'

# --- 6. WSL2's Windows features, no distribution yet ------------------------------------------
# NOT `wsl --install`: on a fresh Windows 11 the inbox wsl.exe stub answers
# "WSL installation appears to be corrupted. Press any key to repair" and waits
# 60 s (seen on homelab-1, 2026-10-16). DISM enables the same two features with
# no prompt; the Mac installs the WSL package and Ubuntu over SSH afterwards
# (homelab/mac/wsl-up.sh).
Step 'WSL2 features (the Mac installs WSL itself and Ubuntu over SSH)'
foreach ($f in 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') {
  dism.exe /online /enable-feature /featurename:$f /all /norestart | Out-Null
  # 0 = done, 3010 = done, reboot required. Anything else is worth stopping for.
  if ($LASTEXITCODE -notin 0, 3010) { throw "DISM could not enable $f (exit $LASTEXITCODE)." }
}
Ok 'enabled; the reboot at the end activates them'

# --- 7. optional rename ---------------------------------------------------------------------------
$name = $env:COMPUTERNAME
if ($NewHostName -and $NewHostName -ne $env:COMPUTERNAME) {
  if ($NewHostName -notmatch '^[A-Za-z0-9-]{1,15}$') { throw '-NewHostName: letters, digits and hyphens, at most 15 characters.' }
  Step "Renaming this PC to $NewHostName (after the next reboot)"
  Rename-Computer -NewName $NewHostName -Force
  $name = $NewHostName
}

# --- the handoff: everything the Mac needs, on screen and on the Desktop -----------------------------
$adapter = Get-NetAdapter -InterfaceIndex $LanIf
$fp      = & "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -lf (Join-Path $SshDir 'ssh_host_ed25519_key.pub')
$cpu     = Get-CimInstance Win32_Processor | Select-Object -First 1
$ramGB   = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$os      = Get-CimInstance Win32_OperatingSystem
$virt    = if ($cpu.VirtualizationFirmwareEnabled) { 'enabled in firmware' } else { 'NOT reported as enabled -- check BIOS/UEFI (Intel VT-x) before running VMs' }
$alias   = $name.ToLower()
# Native commands that write to stderr must not run under 'Stop': Windows
# PowerShell 5.1 turns each stderr line into a terminating error. On a fresh
# PC `wsl --status` prints "WSL installation appears to be corrupted" to
# stderr -- that killed the first real run on homelab-1 right here, before
# the handoff printed. wsl.exe also writes UTF-16, hence the NUL strip.
$ErrorActionPreference = 'Continue'
$wslStatus = try { ((& wsl.exe --status 2>&1 | Out-String) -replace "`0", '').Trim() -replace "\r?\n", ' | ' } catch { '' }
if (-not $wslStatus -or $wslStatus -match 'corrupt|not installed|--install') {
  $wslStatus = 'features enabled; WSL itself not installed yet -- the Mac installs it (homelab/mac/wsl-up.sh)'
}
$ErrorActionPreference = 'Stop'

$handoff = @"
==================== HOMELAB HANDOFF: paste this to the Mac side ====================
hostname      : $name
ssh user      : $env:USERNAME   (administrator)
lan ip        : $($ip.IPAddress)/$($ip.PrefixLength)   via $($adapter.Name)
mac address   : $($adapter.MacAddress)   <- reserve this IP for it in your router (DHCP reservation)
ssh allowed   : from $AllowFrom only, Private networks only, key only
host key      : $fp
windows       : $($os.Caption) $($os.Version) (build $($os.BuildNumber))
cpu           : $($cpu.Name.Trim()), $($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads
ram           : $ramGB GB
virtualization: $virt
wsl           : $wslStatus

Mac side:
  homelab/mac/add-host.sh $alias $($ip.IPAddress) $env:USERNAME
  ssh $alias
=======================================================================================
"@
Write-Host "`n$handoff" -ForegroundColor Yellow
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) "homelab-handoff-$alias.txt"
Set-Content -Path $out -Value $handoff -Encoding utf8
Write-Host "Saved to $out"
Write-Host @"

On first connect, ssh shows the host key above. If it does not match, do not type 'yes'.
Reboot once if the WSL step (or a rename) asked for it. To undo everything:
  powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Uninstall
"@
