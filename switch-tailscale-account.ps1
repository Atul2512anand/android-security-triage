#Requires -Version 5.1
<#
.SYNOPSIS
    Sign this PC out of the current Tailscale account and sign in with your own.

.DESCRIPTION
    Tailscale ties this PC to one account at a time. This script:
      1. Shows the account currently signed in.
      2. Signs this PC out after you confirm.
      3. Opens the Tailscale login flow so you can sign in with your account.
      4. Shows the new account and Tailscale IP.

    Signing out invalidates this PC's node key. The old tailnet may still list
    the PC as an offline device until its owner deletes it, but it can no longer
    connect. Only the owner of the old account can delete that device entry.
#>

$ErrorActionPreference = 'Continue'

function Get-TailscaleExe {
    $command = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = 'C:\Program Files\Tailscale\tailscale.exe'
    if (Test-Path $candidate) { return $candidate }
    return $null
}

function Get-TailscaleState {
    param([string]$TailscaleExe)
    $raw = & $TailscaleExe status --json 2>$null | Out-String
    if (-not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Get-LoginName {
    param($State)
    if (-not $State -or -not $State.Self -or -not $State.Self.UserID) { return $null }
    $user = $State.User.($State.Self.UserID)
    if ($user) { return $user.LoginName }
    return $null
}

$ts = Get-TailscaleExe
if (-not $ts) {
    Write-Host ''
    Write-Host 'Tailscale is not installed or tailscale.exe was not found.' -ForegroundColor Yellow
    Write-Host 'Install it from https://tailscale.com/download/windows'
    Write-Host ''
    exit 1
}

$state = Get-TailscaleState -TailscaleExe $ts
$currentLogin = Get-LoginName -State $state
$currentIp = (& $ts ip -4 2>$null | Select-Object -First 1)
if ($currentIp) { $currentIp = $currentIp.Trim() }

Write-Host ''
Write-Host '=== Switch Tailscale account ===' -ForegroundColor Cyan
Write-Host ''
if ($currentLogin) {
    Write-Host "Current account : $currentLogin"
} else {
    Write-Host 'Current account : (not signed in, or could not read it)'
}
if ($currentIp) {
    Write-Host "Current Tailscale IP: $currentIp"
}
Write-Host ''
Write-Host 'This PC will be signed out of the account above.' -ForegroundColor Yellow
Write-Host 'Have your own Tailscale account ready before you continue.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Do not have one yet? Create it free at:' -ForegroundColor Cyan
Write-Host '  https://login.tailscale.com/start'
Write-Host ''
Write-Host 'Use a private/incognito window or sign out of the old Google account'
Write-Host 'first, so the browser does not auto-select the old account.'
Write-Host ''
Write-Host 'Signing out does NOT delete the old account. It removes this PC from it.'
Write-Host 'The old account owner may still see this PC as an offline device until'
Write-Host 'they delete it from their admin console.'
Write-Host ''

$answer = Read-Host 'Type YES to sign out and continue'
if ($answer -ne 'YES') {
    Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow
    exit 0
}

Write-Host ''
Write-Host 'Signing out...' -ForegroundColor Cyan
& $ts logout
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'Sign-out failed.' -ForegroundColor Yellow
    Write-Host 'Use the Tailscale tray icon instead: right-click it, choose Account,'
    Write-Host 'then Sign out. Then click Log in and use your own account.'
    Write-Host ''
    exit 1
}

Write-Host 'Signed out.' -ForegroundColor Green
Write-Host ''
Write-Host 'A browser will open for the Tailscale login.' -ForegroundColor Cyan
Write-Host 'Sign in with YOUR account. If the browser auto-selects the old account,'
Write-Host 'click "Use another account", or paste the login URL into a private window.'
Write-Host ''
Start-Sleep -Seconds 2

& $ts login

# Wait up to ~90 seconds for the login to complete.
$newState = $null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 3
    $newState = Get-TailscaleState -TailscaleExe $ts
    if ($newState -and $newState.Self -and $newState.Self.UserID) { break }
}

Write-Host ''
$newLogin = Get-LoginName -State $newState
$newIp = (& $ts ip -4 2>$null | Select-Object -First 1)
if ($newIp) { $newIp = $newIp.Trim() }

if ($newLogin) {
    Write-Host "Now signed in as: $newLogin" -ForegroundColor Green
    if ($currentLogin -and $newLogin -eq $currentLogin) {
        Write-Host ''
        Write-Host 'WARNING: this is the same account you just signed out of.' -ForegroundColor Yellow
        Write-Host 'Sign out again and choose "Use another account" in the browser.'
    }
} else {
    Write-Host 'Tailscale is not logged in yet.' -ForegroundColor Yellow
    Write-Host 'Finish the browser sign-in, then run START-HERE.bat -> 10.'
}
if ($newIp) {
    Write-Host "New Tailscale IP: $newIp"
    Write-Host 'The toolkit detects this automatically; no script changes needed.'
}
Write-Host ''
Write-Host 'Removing this PC from the OLD tailnet:' -ForegroundColor Cyan
Write-Host '- If you control the old account: sign in at https://login.tailscale.com'
Write-Host '  -> Machines -> find this PC -> Remove.'
Write-Host '- If you do not control it: ask the old account owner to remove the device.'
Write-Host '  Signing out here is enough to stop this PC from using that tailnet.'
Write-Host ''
