#Requires -Version 5.1
<#
.SYNOPSIS
    Connect to the phone over ADB TCP port 5555 through Tailscale.

.DESCRIPTION
    Use this after the phone owner has run ENABLE-ADB-TCPIP.bat on a
    Windows PC with the phone connected by USB. That switches the phone's
    ADB daemon to TCP port 5555, so the phone can stay on mobile data and
    Tailscale can stay online.

    This script finds the online Android device in Tailscale, connects ADB
    to its Tailscale IP on port 5555, and lists the result.
#>

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Adb = Join-Path $Root 'tools\platform-tools\adb.exe'

if (-not (Test-Path $Adb)) {
    Write-Host ''
    Write-Host 'adb was not found. Run START-HERE.bat once to install the tools.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

function Get-TailscaleExe {
    $command = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = 'C:\Program Files\Tailscale\tailscale.exe'
    if (Test-Path $candidate) { return $candidate }
    return $null
}

function Get-PhoneIp {
    $ts = Get-TailscaleExe
    if (-not $ts) { return $null }

    $raw = & $ts status --json 2>$null | Out-String
    if (-not $raw) { return $null }

    try {
        $state = $raw | ConvertFrom-Json
        $peers = @($state.Peer.PSObject.Properties.Value | Where-Object {
            $_.OS -eq 'android' -and $_.Online
        })
        if ($peers.Count -eq 0) { return $null }

        $peer = $peers[0]
        $ipv4 = @($peer.TailscaleIPs | Where-Object { $_ -match '^\d+\.' })
        if ($ipv4.Count -eq 0) { return $null }

        Write-Host "Phone : $($peer.HostName)" -ForegroundColor Cyan
        Write-Host "IP    : $($ipv4[0])" -ForegroundColor Cyan
        return $ipv4[0]
    }
    catch {
        return $null
    }
}

Write-Host ''
Write-Host '=== Connect over ADB TCP 5555 ===' -ForegroundColor Cyan
Write-Host ''

$phoneIp = Get-PhoneIp
if (-not $phoneIp) {
    Write-Host 'No online Android phone was found in Tailscale.' -ForegroundColor Yellow
    $phoneIp = Read-Host 'Enter the phone Tailscale IP (blank to cancel)'
}
if ([string]::IsNullOrWhiteSpace($phoneIp)) {
    Write-Host 'Cancelled.'
    exit 0
}
$phoneIp = $phoneIp.Trim()

Write-Host ''
Write-Host "Connecting to ${phoneIp}:5555 ..." -ForegroundColor Cyan
& $Adb connect "${phoneIp}:5555"
Start-Sleep -Seconds 2

Write-Host ''
& $Adb devices
Write-Host ''
Write-Host 'If the phone asks "Allow USB debugging?", tap Allow.' -ForegroundColor Yellow
Write-Host 'If it says "connection refused", the owner must run' -ForegroundColor Yellow
Write-Host 'ENABLE-ADB-TCPIP.bat again on the USB-connected PC.' -ForegroundColor Yellow
Write-Host ''
