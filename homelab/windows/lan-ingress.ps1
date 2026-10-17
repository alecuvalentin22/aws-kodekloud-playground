#Requires -Version 5.1
<#
.SYNOPSIS
  Let the home Wi-Fi/LAN (and nothing beyond it) reach the lab: Kubernetes
  ingress 80/443, the RKE2 API 6443 and the playground's 30094/30095/30300,
  which a forwarder inside WSL answers.
.DESCRIPTION
  Run FROM THE MAC over SSH: homelab/mac/lan-ingress.sh copies this file over
  and runs it, like wsl-setup.ps1. Idempotent: a second run changes nothing
  that is already right (the two rules are removed and recreated identically).

  With networkingMode=mirrored (wsl-setup.ps1) a listener in WSL shares
  Windows' ports and addresses, but an inbound packet has to pass TWO firewalls:

    1. Windows Defender Firewall (the host's):
         Homelab-LAN-Ingress-In          TCP -Ports from the LAN subnet, Private profile
    2. The Hyper-V firewall, which filters traffic into the WSL VM and drops it
       by default (DefaultInboundAction = Block):
         Homelab-LAN-Ingress-HyperV-In   same ports, same subnet, same profile,
                                         for the WSL VMCreatorId
       Microsoft's WSL networking page documents New-NetFirewallHyperVRule with
       the WSL creator id {40E0AC32-46A5-438A-A0B2-2B479E8F2E90} for exactly this.
       It adds one rule; it does NOT flip DefaultInboundAction to Allow, which
       would open every port WSL listens on to every address.

  What it does NOT do: touch the SSH rule, the Hyper-V default action, WSL, the
  VMs or anything else; open any port other than -Ports; or open anything on
  Public or Domain networks. -Uninstall removes exactly the two rules above.
.PARAMETER AllowFrom
  Who may connect, as a CIDR. Default: this PC's own LAN subnet, detected from
  the interface that holds the default route (e.g. 192.168.0.0/24), as in bootstrap.ps1.
.PARAMETER Ports
  TCP ports to open, in BOTH rules. Default 80, 443, 6443, 30094, 30095, 30300
  (keep in step with homelab_lan_tcp_forwards in roles/homelab/defaults).
.PARAMETER Uninstall
  Remove the two rules this script added.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\lan-ingress.ps1
#>
[CmdletBinding()]
param(
  [string]  $AllowFrom,
  [int[]]   $Ports = @(80, 443, 6443, 30094, 30095, 30300),
  [switch]  $Uninstall
)
$ErrorActionPreference = 'Stop'
$HostRule  = 'Homelab-LAN-Ingress-In'
$HvRule    = 'Homelab-LAN-Ingress-HyperV-In'
$WslCreator = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'   # WSL's VMCreatorId, from Microsoft Learn

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    ok  $m" -ForegroundColor Green }

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this in an elevated PowerShell (over SSH as an administrator is fine).'
}

# --- uninstall ---------------------------------------------------------------------
if ($Uninstall) {
  Step 'Removing what lan-ingress.ps1 added'
  Get-NetFirewallRule -Name $HostRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  Get-NetFirewallHyperVRule -Name $HvRule -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule
  Ok "$HostRule and $HvRule removed (the SSH rule and WSL are untouched)"
  return
}

# --- validate input -------------------------------------------------------------------
foreach ($p in $Ports) { if ($p -lt 1 -or $p -gt 65535) { throw "Not a TCP port: $p" } }
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
if (-not $route) { throw 'No default route: connect this PC to your network (Wi-Fi or cable) first.' }
$LanIf = $route.InterfaceIndex
if (-not $AllowFrom) {
  $ip = Get-NetIPAddress -InterfaceIndex $LanIf -AddressFamily IPv4 | Select-Object -First 1
  $bytes = ([Net.IPAddress]$ip.IPAddress).GetAddressBytes(); [array]::Reverse($bytes)
  $mask  = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $ip.PrefixLength))
  $net   = [BitConverter]::GetBytes([BitConverter]::ToUInt32($bytes, 0) -band $mask); [array]::Reverse($net)
  $AllowFrom = "$([Net.IPAddress]::new($net))/$($ip.PrefixLength)"
}
if ($AllowFrom -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') { throw "-AllowFrom must be a CIDR such as 192.168.0.0/24 (got '$AllowFrom')." }
if ([int]($AllowFrom.Split('/')[1]) -lt 16) { throw "-AllowFrom $AllowFrom is wider than a home network. Refusing; pass something like /24." }

# Nothing on Windows itself may hold these ports: mirrored mode shares them with WSL.
$busy = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $Ports -contains $_.LocalPort })
if ($busy) {
  $who = ($busy | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort) pid $($_.OwningProcess)" }) -join ', '
  Write-Warning "Windows already listens on: $who -- the forwarder in WSL cannot share those ports."
}

# --- 1. Windows Defender Firewall -------------------------------------------------------
Step "Defender Firewall: TCP $($Ports -join ',') from $AllowFrom, Private networks only"
Get-NetFirewallRule -Name $HostRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -Name $HostRule -DisplayName 'Homelab LAN ingress (LAN only)' `
  -Direction Inbound -Protocol TCP -LocalPort $Ports -Action Allow `
  -RemoteAddress $AllowFrom -Profile Private | Out-Null
# The rules only apply on Private networks, so the home network must be one.
$netProfile = Get-NetConnectionProfile -InterfaceIndex $LanIf
if ($netProfile.NetworkCategory -ne 'Private') {
  Write-Warning "Network '$($netProfile.Name)' is $($netProfile.NetworkCategory), not Private: the rules will not apply to it. bootstrap.ps1 sets Private; this script does not change it."
}
Ok "rule $HostRule"

# --- 2. Hyper-V firewall (into the WSL VM) -------------------------------------------------
Step "Hyper-V firewall (WSL $WslCreator): same ports, same subnet, Private profile"
Get-NetFirewallHyperVRule -Name $HvRule -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule
New-NetFirewallHyperVRule -Name $HvRule -DisplayName 'Homelab LAN ingress into WSL (LAN only)' `
  -Direction Inbound -VMCreatorId $WslCreator -Protocol TCP -LocalPorts $Ports `
  -RemoteAddresses $AllowFrom -Action Allow -Profiles Private | Out-Null
Ok "rule $HvRule"

# --- 3. report ----------------------------------------------------------------------------
Step 'checks'
Get-NetFirewallRule -Name $HostRule | ForEach-Object {
  $pf = $_ | Get-NetFirewallPortFilter; $af = $_ | Get-NetFirewallAddressFilter
  Write-Host "    $($_.Name): enabled=$($_.Enabled) profile=$($_.Profile) $($pf.Protocol) $($pf.LocalPort) from $($af.RemoteAddress)"
}
Get-NetFirewallHyperVRule -Name $HvRule | ForEach-Object {
  Write-Host "    $($_.Name): enabled=$($_.Enabled) profiles=$($_.Profiles) $($_.Protocol) $($_.LocalPorts) from $($_.RemoteAddresses)"
}
$def = (Get-NetFirewallHyperVVMSetting -Name $WslCreator).DefaultInboundAction
Write-Host "    Hyper-V DefaultInboundAction for WSL: $def (left as found)"
Write-Host "`nThe forwarder in WSL is roles/homelab; homelab/mac/lan-ingress.sh runs both halves." -ForegroundColor Cyan
