<#
.SYNOPSIS
  New router / new network: point the home-lab firewall rules at the network this
  PC is on NOW. Run as administrator, on the PC, after it has joined the new network.

.DESCRIPTION
  bootstrap.ps1 and lan-ingress.ps1 only accept traffic from the LAN subnet they saw
  when they ran (e.g. 192.168.1.0/24), and only on a Private network. After a router
  change both are wrong: the subnet is different, and Windows files the new network
  as Public. Every port then times out from the Mac, SSH included, so this cannot
  be fixed from the Mac side.

  This script:
    1. finds the LAN the same way bootstrap.ps1 does (the interface holding the
       default route) and derives its subnet, unless -AllowFrom is given;
    2. sets that network to Private;
    3. re-scopes the three rules to the new subnet, keeping their ports:
         Homelab-SSH-LAN-In              (bootstrap.ps1)
         Homelab-LAN-Ingress-In          (lan-ingress.ps1)
         Homelab-LAN-Ingress-HyperV-In   (lan-ingress.ps1, into WSL)
    4. prints the new IP and the MAC for the Mac side (homelab/mac/readdress.sh)
       and for the DHCP reservation on the router.

  It changes nothing else: no new ports, no SSH config, nothing in WSL.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\readdress.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\readdress.ps1 -AllowFrom 192.168.0.0/24
#>
[CmdletBinding()]
param([string]$AllowFrom)
$ErrorActionPreference = 'Stop'
$SshRule  = 'Homelab-SSH-LAN-In'
$HostRule = 'Homelab-LAN-Ingress-In'
$HvRule   = 'Homelab-LAN-Ingress-HyperV-In'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    ok  $msg" -ForegroundColor Green }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Run this from PowerShell opened with "Run as administrator".' }

# The LAN interface: the one holding the default route (same as bootstrap.ps1).
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
if (-not $route) { throw 'No default route: connect this PC to your network (Wi-Fi or cable) first.' }
$LanIf = $route.InterfaceIndex
$ip = Get-NetIPAddress -InterfaceIndex $LanIf -AddressFamily IPv4 | Select-Object -First 1
if (-not $AllowFrom) {
  $bytes = ([Net.IPAddress]$ip.IPAddress).GetAddressBytes(); [array]::Reverse($bytes)
  $mask  = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $ip.PrefixLength))
  $net   = [BitConverter]::GetBytes([BitConverter]::ToUInt32($bytes, 0) -band $mask); [array]::Reverse($net)
  $AllowFrom = "$([Net.IPAddress]::new($net))/$($ip.PrefixLength)"
}
if ($AllowFrom -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') { throw "-AllowFrom must be a CIDR such as 192.168.0.0/24 (got '$AllowFrom')." }
if ([int]($AllowFrom.Split('/')[1]) -lt 16) { throw "-AllowFrom $AllowFrom is wider than a home network. Refusing; pass something like /24." }

Step "Network profile: Private"
$netProfile = Get-NetConnectionProfile -InterfaceIndex $LanIf
if ($netProfile.NetworkCategory -ne 'Private') {
  Set-NetConnectionProfile -InterfaceIndex $LanIf -NetworkCategory Private
  Ok "network '$($netProfile.Name)' set to Private (it was $($netProfile.NetworkCategory))"
} else { Ok "network '$($netProfile.Name)' is already Private" }

Step "Firewall rules: allow from $AllowFrom"
$missing = @()
foreach ($r in $SshRule, $HostRule) {
  if (Get-NetFirewallRule -Name $r -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -Name $r -RemoteAddress $AllowFrom -Profile Private
    Ok $r
  } else { $missing += $r }
}
if (Get-NetFirewallHyperVRule -Name $HvRule -ErrorAction SilentlyContinue) {
  Set-NetFirewallHyperVRule -Name $HvRule -RemoteAddresses $AllowFrom -Profiles Private
  Ok $HvRule
} else { $missing += $HvRule }
if ($missing) { Write-Warning "Not found (so not changed): $($missing -join ', '). $SshRule comes from bootstrap.ps1, the other two from lan-ingress.ps1." }

Get-NetFirewallRule -Name $SshRule, $HostRule -ErrorAction SilentlyContinue | ForEach-Object {
  $pf = $_ | Get-NetFirewallPortFilter; $af = $_ | Get-NetFirewallAddressFilter
  Write-Host "    $($_.Name): enabled=$($_.Enabled) profile=$($_.Profile) $($pf.Protocol) $($pf.LocalPort) from $($af.RemoteAddress)"
}
Get-NetFirewallHyperVRule -Name $HvRule -ErrorAction SilentlyContinue | ForEach-Object {
  Write-Host "    $($_.Name): enabled=$($_.Enabled) profiles=$($_.Profiles) $($_.Protocol) $($_.LocalPorts) from $($_.RemoteAddresses)"
}

$mac = (Get-NetAdapter -InterfaceIndex $LanIf).MacAddress
$msg = @"

==================== HANDOFF (send this to the Mac side) ====================
ip=$($ip.IPAddress)/$($ip.PrefixLength) mac=$mac allow=$AllowFrom
Mac side:  homelab/mac/readdress.sh $($ip.IPAddress)
Router:    reserve $($ip.IPAddress) for MAC $mac (DHCP reservation), so it stays put.
=============================================================================
"@
Write-Host $msg -ForegroundColor Yellow
