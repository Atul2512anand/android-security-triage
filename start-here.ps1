#Requires -Version 5.1
<#
.SYNOPSIS
    One-click launcher for the Android triage toolkit.
.DESCRIPTION
    Ensures adb, androidqf, scrcpy, MVT and APKiD are installed in this folder,
    then offers a simple menu for connecting a phone, running a scan and opening
    the results. No global installation is performed.
.PARAMETER SetupOnly
    Install/repair tools and exit.
.PARAMETER FullScan
    Connect if needed and run the full scan (collector + androidqf + MVT).
.PARAMETER ConnectOnly
    Only run the wireless-debugging connection flow.
#>
[CmdletBinding()]
param(
    [switch]$SetupOnly,
    [switch]$FullScan,
    [switch]$ConnectOnly,
    [switch]$RemoteSetup,
    [switch]$TailscaleStatus
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Root       = $PSScriptRoot
$Tools      = Join-Path $Root 'tools'
$Venv       = Join-Path $Root '.venv'
$VenvPython = Join-Path $Venv 'Scripts\python.exe'
$CaseRoot   = Join-Path $Root 'cases'

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "[!] $Text" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Text)
    Write-Host "[i] $Text" -ForegroundColor DarkGray
}

function Pause-Any {
    Write-Host ''
    [void](Read-Host 'Press Enter to continue')
}

function Update-ToolPath {
    $paths = @(
        (Join-Path $Tools 'platform-tools'),
        (Join-Path $Tools 'androidqf'),
        (Join-Path $Tools 'scrcpy'),
        (Join-Path $Venv 'Scripts'),
        'C:\Program Files\Tailscale'
    )
    foreach ($p in $paths) {
        if ((Test-Path $p) -and ($env:PATH -notlike "*$p*")) {
            $env:PATH = "$p;$env:PATH"
        }
    }
}

function Ensure-Tools {
    New-Item -ItemType Directory -Force -Path $Tools | Out-Null
    $downloads = Join-Path $Tools '_downloads'
    New-Item -ItemType Directory -Force -Path $downloads | Out-Null

    # --- adb / platform-tools ---------------------------------------------
    $adbPath = Join-Path $Tools 'platform-tools\adb.exe'
    if (-not (Test-Path $adbPath)) {
        Write-Info 'Downloading Android platform-tools (adb)...'
        $zip = Join-Path $downloads 'platform-tools.zip'
        try {
            Invoke-WebRequest 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $zip
            Expand-Archive -Path $zip -DestinationPath $Tools -Force
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Warn "platform-tools download failed: $($_.Exception.Message)"
        }
    }

    # --- androidqf ---------------------------------------------------------
    $aqfPath = Join-Path $Tools 'androidqf\androidqf.exe'
    if (-not (Test-Path $aqfPath)) {
        Write-Info 'Downloading androidqf...'
        New-Item -ItemType Directory -Force -Path (Split-Path $aqfPath) | Out-Null
        try {
            Invoke-WebRequest 'https://github.com/mvt-project/androidqf/releases/download/v1.8.3/androidqf_windows_amd64_1.8.3_unsigned.exe' -OutFile $aqfPath
            Unblock-File -Path $aqfPath -ErrorAction SilentlyContinue
        }
        catch {
            Write-Warn "androidqf download failed: $($_.Exception.Message)"
        }
    }

    # --- scrcpy ------------------------------------------------------------
    $scrcpyPath = Join-Path $Tools 'scrcpy\scrcpy.exe'
    if (-not (Test-Path $scrcpyPath)) {
        Write-Info 'Downloading scrcpy...'
        $zip = Join-Path $downloads 'scrcpy.zip'
        try {
            Invoke-WebRequest 'https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-win64-v5.0.1.zip' -OutFile $zip
            $tmp = Join-Path $downloads 'scrcpy_tmp'
            if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $src = Get-ChildItem $tmp -Directory | Select-Object -First 1
            $dest = Join-Path $Tools 'scrcpy'
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Copy-Item -Path (Join-Path $src.FullName '*') -Destination $dest -Recurse -Force
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Warn "scrcpy download failed: $($_.Exception.Message)"
        }
    }

    # --- Python venv + MVT + APKiD ----------------------------------------
    if (-not (Test-Path $VenvPython)) {
        $py = Get-Command python -ErrorAction SilentlyContinue
        $pyArgs = @()
        if (-not $py) {
            $py = Get-Command py -ErrorAction SilentlyContinue
            if ($py) { $pyArgs = @('-3') }
        }
        if ($py) {
            Write-Info 'Creating Python virtual environment...'
            try {
                & $py.Source @pyArgs -m venv $Venv
            }
            catch {
                Write-Warn "Could not create venv: $($_.Exception.Message)"
            }
        }
        else {
            Write-Warn 'Python not found. Install Python 3.11+ from python.org to enable MVT/APKiD.'
        }
    }

    if (Test-Path $VenvPython) {
        $needMvt   = -not (Test-Path (Join-Path $Venv 'Scripts\mvt-android.exe'))
        $needApkid = -not (Test-Path (Join-Path $Venv 'Scripts\apkid.exe'))
        if ($needMvt -or $needApkid) {
            Write-Info 'Installing MVT and APKiD (first run only, a few minutes)...'
            & $VenvPython -m pip install --disable-pip-version-check --upgrade pip
            $requirements = Join-Path $Root 'requirements.txt'
            if (Test-Path $requirements) {
                & $VenvPython -m pip install --disable-pip-version-check -r $requirements
            }
            else {
                & $VenvPython -m pip install --disable-pip-version-check mvt apkid
            }
        }
    }

    Update-ToolPath
}

function Get-Devices {
    $result = @()
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { return $result }
    $lines = @(& adb devices 2>&1)
    foreach ($line in $lines) {
        if ($line -match '^(\S+)\s+device\s*$') { $result += $Matches[1] }
    }
    return $result
}

function Get-TailscaleExe {
    $command = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = 'C:\Program Files\Tailscale\tailscale.exe'
    if (Test-Path $candidate) { return $candidate }
    return $null
}

function Get-TailscaleSelfIP {
    $ts = Get-TailscaleExe
    if (-not $ts) { return $null }
    $ip = (& $ts ip -4 2>$null | Select-Object -First 1)
    if ($ip) { return $ip.Trim() }
    return $null
}

function Get-TailscalePeers {
    $ts = Get-TailscaleExe
    if (-not $ts) { return @() }
    $raw = & $ts status --json 2>$null | Out-String
    if (-not $raw) { return @() }
    try { $state = $raw | ConvertFrom-Json } catch { return @() }
    if (-not $state.Peer) { return @() }

    $peers = @()
    foreach ($property in $state.Peer.PSObject.Properties) {
        $peer = $property.Value
        $ipv4 = @($peer.TailscaleIPs) | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
        $peers += [pscustomobject]@{
            Name   = $peer.HostName
            OS     = $peer.OS
            Online = [bool]$peer.Online
            IP     = $ipv4
        }
    }
    return $peers
}

function Test-TailscaleReady {
    $ts = Get-TailscaleExe
    if (-not $ts) {
        Write-Warn 'Tailscale is not installed on this PC.'
        Write-Info 'Install it from https://tailscale.com/download/windows and sign in.'
        return $false
    }

    $service = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Running') {
        Write-Warn 'The Tailscale service is not running. Open Tailscale and reconnect.'
        return $false
    }

    $statusText = (& $ts status 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $statusText -match 'Logged out|not logged in|NeedsLogin') {
        Write-Warn 'Tailscale is not logged in on this PC.'
        Write-Info 'Open Tailscale, sign in, then retry.'
        Start-Process 'https://login.tailscale.com/'
        return $false
    }
    return $true
}

function Show-TailscaleStatus {
    if (-not (Test-TailscaleReady)) { return }

    Write-Head 'Tailscale status'
    $ts = Get-TailscaleExe
    & $ts status

    $selfIp = Get-TailscaleSelfIP
    if ($selfIp) { Write-Ok "This PC: $selfIp" }

    $androidPeers = @(Get-TailscalePeers | Where-Object { $_.OS -eq 'android' })
    Write-Host ''
    if ($androidPeers.Count -eq 0) {
        Write-Warn 'No Android device is visible in this tailnet yet.'
        Write-Info 'Invite the owner to your tailnet: https://login.tailscale.com/admin/users'
        Write-Info 'Or have them share the phone with you: https://login.tailscale.com/admin/machines'
        Write-Info 'On the phone: install Tailscale from Play Store, sign in, turn the VPN on.'
    }
    else {
        Write-Host 'Android devices in the tailnet:'
        foreach ($peer in $androidPeers) {
            $state = if ($peer.Online) { 'online' } else { 'OFFLINE' }
            Write-Host ("  {0}  {1}  [{2}]" -f $peer.Name, $peer.IP, $state)
        }
    }
}

function Show-Status {
    $adbOk   = Test-Path (Join-Path $Tools 'platform-tools\adb.exe')
    $aqfOk   = Test-Path (Join-Path $Tools 'androidqf\androidqf.exe')
    $scrOk   = Test-Path (Join-Path $Tools 'scrcpy\scrcpy.exe')
    $mvtOk   = Test-Path (Join-Path $Venv 'Scripts\mvt-android.exe')
    $apkidOk = Test-Path (Join-Path $Venv 'Scripts\apkid.exe')
    $devices = Get-Devices

    $mark = { param($ok) if ($ok) { 'OK' } else { 'MISSING' } }
    $tailscaleOk = [bool](Get-TailscaleExe)
    $pythonOk = Test-Path $VenvPython
    Write-Host ("  adb ........ {0}    androidqf ... {1}    scrcpy ... {2}" -f (& $mark $adbOk), (& $mark $aqfOk), (& $mark $scrOk))
    Write-Host ("  MVT ........ {0}    APKiD ....... {1}" -f (& $mark $mvtOk), (& $mark $apkidOk))
    Write-Host ("  tailscale .. {0}    python ...... {1}" -f (& $mark $tailscaleOk), (& $mark $pythonOk))
    if ($devices.Count -gt 0) {
        Write-Host ("  phone ...... CONNECTED: {0}" -f ($devices -join ', ')) -ForegroundColor Green
    }
    else {
        Write-Host '  phone ...... not connected' -ForegroundColor Yellow
    }
}

function Select-Device {
    $devices = Get-Devices
    if ($devices.Count -eq 0) { return $null }
    if ($devices.Count -eq 1) { return $devices[0] }
    Write-Host 'Multiple devices connected:'
    for ($i = 0; $i -lt $devices.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), $devices[$i])
    }
    $selection = Read-Host 'Select device number'
    $index = 0
    if ([int]::TryParse($selection, [ref]$index) -and $index -ge 1 -and $index -le $devices.Count) {
        return $devices[$index - 1]
    }
    return $devices[0]
}

function Connect-LocalPhone {
    $devices = Get-Devices
    if ($devices.Count -gt 0) {
        Write-Ok "Already connected: $($devices -join ', ')"
        return
    }

    Write-Head 'Connect phone over same Wi-Fi or USB'
    Write-Host 'On the phone:'
    Write-Host '  1. Settings > About phone > Software information > tap Build number 7 times'
    Write-Host '  2. Settings > Developer options > Wireless debugging > ON'
    Write-Host '  3. Tap "Pair device with pairing code"'
    Write-Host ''
    Write-Info 'USB cable? Skip this and just plug it in with USB debugging enabled.'
    Write-Host ''

    $pairAddress = Read-Host 'PAIRING IP:PORT from the popup (blank to cancel)'
    if ([string]::IsNullOrWhiteSpace($pairAddress)) { return }

    Write-Host 'Enter the 6-digit code when adb prompts...' -ForegroundColor Cyan
    & adb pair $pairAddress
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'Pairing failed. Re-open the pairing popup (codes expire) and retry.'
        return
    }

    $connectAddress = Read-Host 'CONNECT IP:PORT from the Wireless debugging screen'
    if ([string]::IsNullOrWhiteSpace($connectAddress)) { return }

    & adb connect $connectAddress
    Start-Sleep -Seconds 1
    $devices = Get-Devices
    if ($devices.Count -gt 0) {
        Write-Ok "Connected: $($devices -join ', ')"
    }
    else {
        Write-Warn 'Not connected. Check the port, unlock the phone, and retry.'
    }
}

function Connect-RemotePhone {
    Write-Head 'Remote connection over Tailscale'
    if (-not (Test-TailscaleReady)) { return }

    $selfIp = Get-TailscaleSelfIP
    Write-Ok "This PC's Tailscale IP: $selfIp"

    Write-Host ''
    Write-Host 'The phone owner must:'
    Write-Host '  1. Install Tailscale from the Play Store.'
    Write-Host '  2. Sign in and turn the Tailscale VPN on.'
    Write-Host '  3. Join YOUR tailnet (accept your invite) OR share the phone with you.'
    Write-Host '  4. Keep Tailscale connected during the scan.'
    Write-Host ''
    Write-Info 'Invite: https://login.tailscale.com/admin/users'
    Write-Info 'Share:  https://login.tailscale.com/admin/machines'
    $openPage = Read-Host 'Open the Tailscale admin page now? (Y/n)'
    if ($openPage -notmatch '^[nN]') {
        Start-Process 'https://login.tailscale.com/admin/machines'
    }

    Write-Host ''
    Write-Info 'Waiting for an Android device in the tailnet...'
    $androidPeers = @(Get-TailscalePeers | Where-Object { $_.OS -eq 'android' })
    if ($androidPeers.Count -eq 0) {
        Write-Warn 'No Android device visible yet.'
        [void](Read-Host 'Press Enter to refresh after the owner connects Tailscale')
        $androidPeers = @(Get-TailscalePeers | Where-Object { $_.OS -eq 'android' })
    }

    $fallbackListing = $false
    if ($androidPeers.Count -eq 0) {
        $onlinePeers = @(Get-TailscalePeers | Where-Object { $_.Online })
        if ($onlinePeers.Count -gt 0) {
            Write-Warn 'No peer reports itself as Android.'
            Write-Info 'Showing all online peers - pick the phone by name or IP.'
            $androidPeers = $onlinePeers
            $fallbackListing = $true
        }
    }

    if ($androidPeers.Count -eq 0) {
        Write-Warn 'Still no Android device. Fix Tailscale on the phone, or use same Wi-Fi/USB.'
        return
    }

    if ($fallbackListing) {
        Write-Host 'Online Tailscale peers:'
    }
    else {
        Write-Host 'Android devices in the tailnet:'
    }
    for ($i = 0; $i -lt $androidPeers.Count; $i++) {
        $peer = $androidPeers[$i]
        $state = if ($peer.Online) { 'online' } else { 'OFFLINE' }
        Write-Host ("  {0}) {1}  {2}  [{3}]" -f ($i + 1), $peer.Name, $peer.IP, $state)
    }

    $selection = Read-Host 'Select the phone'
    $index = 0
    if (-not [int]::TryParse($selection, [ref]$index)) { $index = 1 }
    if ($index -lt 1 -or $index -gt $androidPeers.Count) { $index = 1 }
    $phoneIp = $androidPeers[$index - 1].IP
    if (-not $phoneIp) {
        Write-Warn 'Could not read the Tailscale IP of that device.'
        return
    }
    if (-not $androidPeers[$index - 1].Online) {
        Write-Warn 'That phone shows OFFLINE in Tailscale. Ask the owner to open the Tailscale app.'
    }

    Write-Host ''
    Write-Host "Phone Tailscale IP: $phoneIp" -ForegroundColor Cyan

    $ts = Get-TailscaleExe
    if ($ts) {
        Write-Info "Testing Tailscale reachability to $phoneIp"
        $pingText = (& $ts ping -c 1 $phoneIp 2>&1 | Out-String)
        if ($pingText -match 'pong from') {
            Write-Ok 'Tailscale reachability OK'
        }
        else {
            Write-Warn 'Tailscale cannot reach the phone yet.'
            Write-Info 'Path B: confirm the owner accepted the share.'
            Write-Info 'Path A: confirm the owner signed in with the invited email.'
            Write-Info 'If the share path keeps failing, switch to the invite path (A).'
            Write-Host ''
            $continue = Read-Host 'Try ADB anyway? (y/N)'
            if ($continue -notmatch '^[yY]') { return }
        }
    }

    Write-Host 'On the phone: Developer options > Wireless debugging > Pair device with pairing code'
    Write-Info 'Use only the PORT from the popup. The script already knows the Tailscale IP.'
    $pairInput = Read-Host 'PAIRING PORT (or full IP:PORT - only the port is used)'
    if ([string]::IsNullOrWhiteSpace($pairInput)) { return }
    $pairPort = ($pairInput -split ':')[-1].Trim()
    if ($pairPort -notmatch '^\d+$') {
        Write-Warn 'That does not look like a port number.'
        return
    }
    $pairAddress = '{0}:{1}' -f $phoneIp, $pairPort

    Write-Host 'Enter the 6-digit code when adb prompts...' -ForegroundColor Cyan
    & adb pair $pairAddress
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'Pairing failed. Re-open the pairing popup (codes expire) and retry.'
        return
    }

    Write-Host ''
    Write-Info 'Use only the PORT from the Wireless debugging screen (not the pairing port).'
    $connectInput = Read-Host 'CONNECT PORT (or full IP:PORT - only the port is used)'
    if ([string]::IsNullOrWhiteSpace($connectInput)) { return }
    $connectPort = ($connectInput -split ':')[-1].Trim()
    if ($connectPort -notmatch '^\d+$') {
        Write-Warn 'That does not look like a port number.'
        return
    }
    $connectAddress = '{0}:{1}' -f $phoneIp, $connectPort

    & adb connect $connectAddress
    $authorizationHintShown = $false
    $devices = @()
    for ($attempt = 1; $attempt -le 15; $attempt++) {
        Start-Sleep -Seconds 2
        $devices = Get-Devices
        if ($devices.Count -gt 0) { break }

        $deviceLines = @(& adb devices 2>&1)
        if (-not $authorizationHintShown -and ($deviceLines -match 'unauthorized')) {
            Write-Info 'Waiting for the phone: tap Allow on the "Allow USB debugging?" prompt.'
            $authorizationHintShown = $true
        }
    }

    if ($devices.Count -gt 0) {
        Write-Ok "Connected over Tailscale: $($devices -join ', ')"
        Write-Info 'Keep the phone unlocked, charging, and Tailscale on during the scan.'
    }
    else {
        Write-Warn 'Not connected. Check that the phone is unlocked, Tailscale is on,'
        Write-Warn 'and the CONNECT PORT matches the Wireless debugging screen.'
    }
}

function Connect-Phone {
    $devices = Get-Devices
    if ($devices.Count -gt 0) {
        Write-Ok "Already connected: $($devices -join ', ')"
        return
    }

    Write-Head 'Connect phone'
    Write-Host '  1) Remote over Tailscale  (recommended - phone is on another network)'
    Write-Host '  2) Same Wi-Fi / USB cable'
    $mode = Read-Host 'Choose connection type [1]'
    if ($mode -eq '2') { Connect-LocalPhone } else { Connect-RemotePhone }
}

function Open-LastCase {
    if (-not (Test-Path $CaseRoot)) {
        Write-Warn 'No case folder exists yet. Run a scan first.'
        return
    }
    $latest = Get-ChildItem -Path $CaseRoot -Directory |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latest) {
        Write-Warn 'No case folder exists yet. Run a scan first.'
        return
    }
    Write-Ok "Opening $($latest.FullName)"
    Invoke-Item $latest.FullName
}

function Run-Scan {
    param(
        [ValidateSet('Full', 'Quick', 'Deep')]
        [string]$Mode = 'Quick'
    )

    $serial = Select-Device
    if (-not $serial) {
        Write-Warn 'No phone connected. Starting the connection flow...'
        Connect-Phone
        $serial = Select-Device
        if (-not $serial) { return }
    }

    $scanArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'android-triage.ps1'),
        '-Serial', $serial,
        '-PullApks'
    )
    switch ($Mode) {
        'Full' { $scanArgs += '-WithMvt' }
        'Deep' { $scanArgs += @('-WithAndroidqf', '-RunMvt') }
    }

    $label = switch ($Mode) {
        'Full' { 'Full scan (collector + bugreport + MVT)' }
        'Deep' { 'Deep androidqf acquisition (interactive)' }
        default { 'Quick scan (collector + APK pull)' }
    }
    Write-Head $label
    if ($Mode -eq 'Full') {
        Write-Info 'Bugreport collection can take 5-15 minutes over a remote connection.'
    }
    if ($Mode -eq 'Deep') {
        Write-Info 'androidqf asks questions in this window. Answer them to continue.'
    }
    Write-Info 'Keep the phone unlocked and connected until the scan finishes.'
    & powershell @scanArgs

    if (Test-Path $CaseRoot) {
        $latest = Get-ChildItem -Path $CaseRoot -Directory |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest) {
            Write-Ok "Case folder: $($latest.FullName)"
            $summary = Join-Path $latest.FullName 'summary.txt'
            if (Test-Path $summary) {
                $answer = Read-Host 'Open summary.txt now? (Y/n)'
                if ($answer -notmatch '^[nN]') { Invoke-Item $summary }
            }
        }
    }
}

function Open-PhoneScreen {
    $serial = Select-Device
    if (-not $serial) {
        Connect-Phone
        $serial = Select-Device
        if (-not $serial) { return }
    }
    $scrcpy = Join-Path $Tools 'scrcpy\scrcpy.exe'
    if (-not (Test-Path $scrcpy)) {
        Write-Warn 'scrcpy is not installed. Choose option 8 to repair tools.'
        return
    }
    Write-Info 'Close the phone window to return.'
    & $scrcpy -s $serial
}

function Start-MobSF {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) {
        Write-Warn 'Docker not found. Install Docker Desktop to use MobSF.'
        return
    }
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'Docker Desktop is not running. Start it, then choose this option again.'
        return
    }
    Write-Info 'Starting MobSF. First run downloads the image (~1 GB).'
    Start-Process powershell -ArgumentList @(
        '-NoExit', '-Command',
        'docker run --rm -it -p 8000:8000 opensecurity/mobile-security-framework-mobsf:latest'
    )
    Start-Sleep -Seconds 5
    Start-Process 'http://localhost:8000'
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host '=====================================================' -ForegroundColor Cyan
        Write-Host '  Android Phone Security Triage'       -ForegroundColor Cyan
        Write-Host '=====================================================' -ForegroundColor Cyan
        Show-Status
        Write-Host ''
        Write-Host '  1) Connect phone (remote via Tailscale / local)'
        Write-Host '  2) FULL scan  (collector + bugreport + MVT)'
        Write-Host '  3) Quick scan (collector + APK pull)'
        Write-Host '  4) Deep androidqf acquisition (interactive)'
        Write-Host '  5) Open last case folder'
        Write-Host '  6) Open live phone screen (scrcpy)'
        Write-Host '  7) Start MobSF APK scanner (Docker, optional)'
        Write-Host '  8) Check / repair tools'
        Write-Host '  9) Show ADB device list'
        Write-Host ' 10) Tailscale status / remote help'
        Write-Host ' 11) Switch Tailscale account'
        Write-Host '  0) Exit'
        Write-Host ''

        $choice = Read-Host 'Choose'
        switch ($choice) {
            '1' { Connect-Phone; Pause-Any }
            '2' { Run-Scan -Mode Full; Pause-Any }
            '3' { Run-Scan -Mode Quick; Pause-Any }
            '4' { Run-Scan -Mode Deep; Pause-Any }
            '5' { Open-LastCase; Pause-Any }
            '6' { Open-PhoneScreen; Pause-Any }
            '7' { Start-MobSF; Pause-Any }
            '8' { Ensure-Tools; Show-Status; Pause-Any }
            '9' { & adb devices -l; Pause-Any }
            '10' { Show-TailscaleStatus; Pause-Any }
            '11' {
                & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'switch-tailscale-account.ps1')
                Pause-Any
            }
            '0' { return }
            default {
                Write-Warn 'Invalid choice.'
                Start-Sleep -Seconds 1
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

try {
    Ensure-Tools

    if ($SetupOnly) {
        Show-Status
        exit 0
    }
    if ($TailscaleStatus) {
        Show-TailscaleStatus
        exit 0
    }
    if ($RemoteSetup) {
        Connect-RemotePhone
        exit 0
    }
    if ($ConnectOnly) {
        Connect-Phone
        exit 0
    }
    if ($FullScan) {
        Run-Scan -Mode Full
        exit 0
    }

    Show-Menu
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    [void](Read-Host 'Press Enter to exit')
    exit 1
}
