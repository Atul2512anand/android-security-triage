#Requires -Version 5.1
<#
.SYNOPSIS
    Android triage collector for a consented security audit (Samsung A16 / any ADB device).

.DESCRIPTION
    Collects device integrity properties, package inventory, dumpsys state, settings,
    accounts, processes and a bounded logcat over ADB - USB, Wi-Fi or Tailscale
    wireless debugging.

    Output is a timestamped case folder containing:
      summary.txt              - parsed red flags + device overview
      packages_thirdparty.txt  - installed apps + installer + APK path
      device_policy.txt        - active device admins
      accessibility.txt        - enabled accessibility services (main stalkerware vector)
      settings_secure.txt      - accessibility / notification listener settings
      settings_global.txt      - VPN, Private DNS, developer options state
      dumpsys_package.txt      - full package metadata (install times, permissions)
      accounts.txt             - accounts registered on the device
      processes.txt            - running processes
      logcat_tail.txt          - last 5000 log lines
      README.txt               - next steps (MVT, MobSF, APKiD)
      commands.log             - exact commands executed (chain of custody)

    This is a manual-review snapshot, not a full forensic image. For MVT analysis,
    use -WithMvt (automatic bugreport path) or -WithAndroidqf (deeper, interactive).

.PARAMETER OutputDir
    Root folder for case output. Default: .\cases

.PARAMETER Serial
    ADB serial, e.g. 192.168.1.5:41235. Auto-detected if exactly one device is attached.

.PARAMETER PullApks
    Pull APKs of sideloaded third-party packages (installer=null) into .\apks.

.PARAMETER WithMvt
    Collect an Android bugreport over ADB and run MVT 'check-bugreport' on it.
    This is fully automatic and is the recommended MVT path for remote phones.

.PARAMETER WithAndroidqf
    Run androidqf interactively into .\androidqf for a deeper acquisition.
    androidqf 1.8.3 asks questions in the console; answer them when prompted.

.PARAMETER RunMvt
    Run MVT on the androidqf output. Use together with -WithAndroidqf.

.EXAMPLE
    .\android-triage.ps1

.EXAMPLE
    .\android-triage.ps1 -Serial 192.168.1.5:41235 -OutputDir D:\cases -PullApks

.NOTES
    Use only on devices you own or have written consent to examine.
    Requires adb in PATH (Android platform-tools).
#>
[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path (Get-Location) 'cases'),
    [string]$Serial,
    [switch]$PullApks,
    [switch]$WithMvt,
    [switch]$WithAndroidqf,
    [switch]$RunMvt
)

$ErrorActionPreference = 'Continue'

# Make the script usable on its own: prefer tools installed in this folder.
$localToolPaths = @(
    (Join-Path $PSScriptRoot 'tools\platform-tools'),
    (Join-Path $PSScriptRoot 'tools\androidqf'),
    (Join-Path $PSScriptRoot 'tools\scrcpy'),
    (Join-Path $PSScriptRoot '.venv\Scripts')
)
foreach ($localPath in $localToolPaths) {
    if ((Test-Path $localPath) -and ($env:PATH -notlike "*$localPath*")) {
        $env:PATH = "$localPath;$env:PATH"
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Green
}

function Write-Note {
    param([string]$Message)
    Write-Host "[i] $Message" -ForegroundColor DarkGray
}

function Get-PropValue {
    param([string]$Text, [string]$Key)
    $pattern = '\[\s*' + [regex]::Escape($Key) + '\s*\]\s*:\s*\[([^\]]*)\]'
    $m = [regex]::Match($Text, $pattern)
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return 'unknown'
}

function Get-SettingValue {
    param([string]$Text, [string]$Key)
    $pattern = '(?m)^' + [regex]::Escape($Key) + '=(.*)$'
    $m = [regex]::Match($Text, $pattern)
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

# ---------------------------------------------------------------------------
# 0. Environment and device selection
# ---------------------------------------------------------------------------

if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    throw "adb not found in PATH. Download Android platform-tools and add the folder to PATH."
}

$deviceLines = @(& adb devices 2>&1)
$devices = @()
foreach ($line in $deviceLines) {
    if ($line -match '^(\S+)\s+(device|unauthorized|offline)\s*$') {
        $devices += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2] }
    }
}

if (-not $Serial) {
    $ready = @($devices | Where-Object { $_.State -eq 'device' })
    if ($ready.Count -eq 0) {
        $unauthorized = @($devices | Where-Object { $_.State -eq 'unauthorized' })
        if ($unauthorized.Count -gt 0) {
            throw "Device is unauthorized. Unlock the phone and tap 'Allow USB debugging' / re-pair wireless debugging, then retry."
        }
        throw "No authorized device found. On the phone: Developer options -> Wireless debugging -> Pair device with pairing code. Then run: adb pair <ip>:<pair-port> ; adb connect <ip>:<connect-port>"
    }
    if ($ready.Count -gt 1) {
        $list = ($ready | ForEach-Object { $_.Serial }) -join ', '
        throw "Multiple devices connected: $list. Re-run with -Serial <serial>."
    }
    $Serial = $ready[0].Serial
}

$adbPrefix = @('-s', $Serial)
$state = ((& adb @adbPrefix get-state 2>$null) | Out-String).Trim()
if ($state -ne 'device') {
    throw "Device $Serial is not in 'device' state (got '$state')."
}
Write-Ok "Using device: $Serial"

# ---------------------------------------------------------------------------
# 1. Case folder
# ---------------------------------------------------------------------------

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$caseDir = Join-Path $OutputDir "a16_$stamp"
$apkDir = Join-Path $caseDir 'apks'
New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
New-Item -ItemType Directory -Force -Path $apkDir | Out-Null
$commandsLog = Join-Path $caseDir 'commands.log'
Write-Ok "Case folder: $caseDir"

# ---------------------------------------------------------------------------
# 2. Collection
# ---------------------------------------------------------------------------

$collections = [ordered]@{
    'getprop.txt'             = @('shell', 'getprop')
    'packages_all.txt'        = @('shell', 'pm', 'list', 'packages', '-f', '-i', '-U')
    'packages_thirdparty.txt' = @('shell', 'pm', 'list', 'packages', '-3', '-f', '-i')
    'packages_system.txt'     = @('shell', 'pm', 'list', 'packages', '-s', '-i')
    'device_policy.txt'       = @('shell', 'dumpsys', 'device_policy')
    'accessibility.txt'       = @('shell', 'dumpsys', 'accessibility')
    'appops.txt'              = @('shell', 'dumpsys', 'appops')
    'users.txt'               = @('shell', 'pm', 'list', 'users')
    'processes.txt'           = @('shell', 'ps', '-A')
    'services.txt'            = @('shell', 'dumpsys', 'activity', 'services')
    'settings_secure.txt'     = @('shell', 'settings', 'list', 'secure')
    'settings_global.txt'     = @('shell', 'settings', 'list', 'global')
    'settings_system.txt'     = @('shell', 'settings', 'list', 'system')
    'network.txt'             = @('shell', 'dumpsys', 'connectivity')
    'accounts.txt'            = @('shell', 'dumpsys', 'account')
    'dumpsys_package.txt'     = @('shell', 'dumpsys', 'package')
}

$collectionErrors = @()

foreach ($name in $collections.Keys) {
    $argsList = $collections[$name]
    $allArgs = $adbPrefix + $argsList
    Write-Step "Collecting $name"
    "adb $($allArgs -join ' ')" | Out-File -FilePath $commandsLog -Encoding utf8 -Append
    try {
        $output = & adb @allArgs 2>&1 | Out-String -Width 8192
        $output | Out-File -FilePath (Join-Path $caseDir $name) -Encoding utf8
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    exit code $LASTEXITCODE" -ForegroundColor Yellow
        }
    }
    catch {
        $collectionErrors += "$name : $($_.Exception.Message)"
        Write-Host "    failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Step 'Collecting logcat (last 5000 lines)'
"adb $($adbPrefix -join ' ') logcat -d -t 5000 -v threadtime" | Out-File -FilePath $commandsLog -Encoding utf8 -Append
try {
    & adb @adbPrefix logcat -d -t 5000 -v threadtime 2>&1 |
        Out-File -FilePath (Join-Path $caseDir 'logcat_tail.txt') -Encoding utf8
}
catch {
    $collectionErrors += "logcat : $($_.Exception.Message)"
}

if ($collectionErrors.Count -gt 0) {
    $collectionErrors | Out-File -FilePath (Join-Path $caseDir 'errors.txt') -Encoding utf8
}

# ---------------------------------------------------------------------------
# 3. Parse and summarise
# ---------------------------------------------------------------------------

function Read-CaseFile {
    param([string]$Name)
    $path = Join-Path $caseDir $Name
    if (Test-Path $path) { return (Get-Content -Path $path -Raw) }
    return ''
}

$getprop     = Read-CaseFile 'getprop.txt'
$thirdParty  = Read-CaseFile 'packages_thirdparty.txt'
$secure      = Read-CaseFile 'settings_secure.txt'
$global      = Read-CaseFile 'settings_global.txt'
$devicePolicy = Read-CaseFile 'device_policy.txt'
$usersText   = Read-CaseFile 'users.txt'
$accountsText = Read-CaseFile 'accounts.txt'

$model      = Get-PropValue $getprop 'ro.product.model'
$androidVer = Get-PropValue $getprop 'ro.build.version.release'
$fingerprint = Get-PropValue $getprop 'ro.build.fingerprint'
$securityPatch = Get-PropValue $getprop 'ro.build.version.security_patch'
$verifiedBoot = Get-PropValue $getprop 'ro.boot.verifiedbootstate'
$knoxBit    = Get-PropValue $getprop 'ro.boot.warranty_bit'
$bootLocked = Get-PropValue $getprop 'ro.boot.flash.locked'
$debuggable = Get-PropValue $getprop 'ro.debuggable'
$secureProp = Get-PropValue $getprop 'ro.secure'

$flags = New-Object System.Collections.Generic.List[string]
$sideloaded = New-Object System.Collections.Generic.List[string]
$thirdPartyRows = New-Object System.Collections.Generic.List[string]

$knownInstallers = @(
    'com.android.vending',
    'com.sec.android.app.samsungapps',
    'com.google.android.packageinstaller',
    'com.android.packageinstaller',
    'com.samsung.android.packageinstaller'
)

foreach ($line in ($thirdParty -split '\r?\n')) {
    if ($line -match '^package:(?<path>.*)=(?<pkg>[^\s=]+)\s+installer=(?<inst>\S*)\s*$') {
        $pkgName = $Matches['pkg']
        $installer = $Matches['inst']
        $apkPath = $Matches['path']
        $thirdPartyRows.Add(('{0}  [installer={1}]' -f $pkgName, $installer))

        if ([string]::IsNullOrWhiteSpace($installer) -or $installer -eq 'null') {
            $sideloaded.Add($pkgName)
            $flags.Add("SIDELOADED APP: $pkgName (installer=null, no store)")
        }
        elseif ($knownInstallers -notcontains $installer) {
            $flags.Add("UNUSUAL INSTALLER: $pkgName (installer=$installer)")
        }
    }
}

$accessibilityValue = Get-SettingValue $secure 'enabled_accessibility_services'
$accessibilityOn = Get-SettingValue $secure 'accessibility_enabled'
$notificationValue = Get-SettingValue $secure 'enabled_notification_listeners'
$vpnApp = Get-SettingValue $global 'always_on_vpn_app'
$privateDnsMode = Get-SettingValue $global 'private_dns_mode'
$privateDnsSpecifier = Get-SettingValue $global 'private_dns_specifier'
$devSettings = Get-SettingValue $global 'development_settings_enabled'
$adbEnabled = Get-SettingValue $global 'adb_enabled'

if ($accessibilityValue -and $accessibilityValue -ne 'null') {
    foreach ($service in ($accessibilityValue -split ':')) {
        if ($service.Trim()) {
            $flags.Add("ACCESSIBILITY SERVICE: $($service.Trim())")
        }
    }
}

if ($notificationValue -and $notificationValue -ne 'null') {
    foreach ($listener in ($notificationValue -split ':')) {
        if ($listener.Trim()) {
            $flags.Add("NOTIFICATION LISTENER: $($listener.Trim())")
        }
    }
}

$admins = @()
$adminMatches = [regex]::Matches($devicePolicy, 'ComponentInfo\{([^}]+)\}')
foreach ($match in $adminMatches) { $admins += $match.Groups[1].Value }
$admins = @($admins | Sort-Object -Unique)

$userCount = ([regex]::Matches($usersText, 'UserInfo\{')).Count
$accountCount = ([regex]::Matches($accountsText, '(?m)^\s*Account \{')).Count

if ($userCount -gt 1) {
    $flags.Add("MULTIPLE ANDROID USERS/PROFILES: $userCount (check for hidden work profile or Secure Folder)")
}

if ($verifiedBoot -and $verifiedBoot -ne 'green' -and $verifiedBoot -ne 'unknown') {
    $flags.Add("VERIFIED BOOT NOT GREEN: $verifiedBoot (system partition may be modified)")
}
if ($knoxBit -eq '1') {
    $flags.Add('KNOX WARRANTY BIT TRIPPED: 1 (device was rooted/flashed)')
}
if ($bootLocked -eq '0') {
    $flags.Add('BOOTLOADER UNLOCKED (ro.boot.flash.locked=0)')
}
if ($debuggable -eq '1') {
    $flags.Add('ro.debuggable=1 (debug build or tampered)')
}
if ($devSettings -eq '1') {
    $flags.Add('DEVELOPER OPTIONS ENABLED (check whether the owner enabled them)')
}
if ($vpnApp -and $vpnApp -ne 'null') {
    $flags.Add("ALWAYS-ON VPN: $vpnApp")
}
if ($privateDnsSpecifier) {
    $flags.Add("PRIVATE DNS HOSTNAME: $privateDnsSpecifier")
}

# ---------------------------------------------------------------------------
# 4. APK pull (optional)
# ---------------------------------------------------------------------------

$apkHashes = New-Object System.Collections.Generic.List[string]

if ($PullApks -and $sideloaded.Count -gt 0) {
    foreach ($pkgName in $sideloaded) {
        Write-Step "Pulling APK for $pkgName"
        try {
            $pathLines = @(& adb @adbPrefix shell pm path $pkgName 2>&1)
            foreach ($pathLine in $pathLines) {
                if ($pathLine -match '^package:(.+)$') {
                    $remote = $Matches[1].Trim()
                    $leaf = ($remote -split '/')[-1]
                    $local = Join-Path $apkDir ('{0}-{1}' -f $pkgName, $leaf)
                    & adb @adbPrefix pull $remote $local 2>&1 | Out-Null
                    if (Test-Path $local) {
                        $hash = Get-FileHash -Path $local -Algorithm SHA256
                        $apkHashes.Add(('{0}  {1}' -f $hash.Hash, (Split-Path $local -Leaf)))
                    }
                }
            }
        }
        catch {
            $collectionErrors += "pull $pkgName : $($_.Exception.Message)"
        }
    }
}

if ($apkHashes.Count -gt 0) {
    $apkHashes | Out-File -FilePath (Join-Path $caseDir 'apk_hashes.txt') -Encoding utf8
}

# ---------------------------------------------------------------------------
# 5. Summary + README
# ---------------------------------------------------------------------------

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('ANDROID TRIAGE SUMMARY')
$summary.Add('=====================')
$summary.Add('')
$summary.Add("Serial:            $Serial")
$summary.Add("Collected:         $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$summary.Add("Case folder:       $caseDir")
$summary.Add('')
$summary.Add('DEVICE')
$summary.Add('------')
$summary.Add("Model:             $model")
$summary.Add("Android:           $androidVer")
$summary.Add("Security patch:    $securityPatch")
$summary.Add("Fingerprint:       $fingerprint")
$summary.Add('')
$summary.Add('INTEGRITY')
$summary.Add('---------')
$summary.Add("Verified boot:     $verifiedBoot            (expect: green)")
$summary.Add("Knox warranty bit: $knoxBit            (expect: 0)")
$summary.Add("Bootloader locked: $bootLocked            (expect: 1)")
$summary.Add("ro.debuggable:     $debuggable            (expect: 0)")
$summary.Add("ro.secure:         $secureProp            (expect: 1)")
$summary.Add('')
$summary.Add('AUTOMATIC FLAGS')
$summary.Add('---------------')
if ($flags.Count -eq 0) {
    $summary.Add('None. Manual review of the collected files is still required.')
}
else {
    foreach ($flag in $flags) { $summary.Add("  - $flag") }
}
$summary.Add('')
$summary.Add("THIRD-PARTY PACKAGES ($($thirdPartyRows.Count))")
$summary.Add('-----------------------')
foreach ($row in $thirdPartyRows) { $summary.Add("  $row") }
$summary.Add('')
$summary.Add('ACCESSIBILITY')
$summary.Add('-------------')
$summary.Add("accessibility_enabled: $accessibilityOn")
$summary.Add("services:              $(if ($accessibilityValue) { $accessibilityValue } else { '(none)' })")
$summary.Add('')
$summary.Add('NOTIFICATION LISTENERS')
$summary.Add('----------------------')
$summary.Add($(if ($notificationValue) { $notificationValue } else { '(none)' }))
$summary.Add('')
$summary.Add('DEVICE ADMINS (verify each)')
$summary.Add('---------------------------')
if ($admins.Count -eq 0) { $summary.Add('  (none detected)') }
else { foreach ($admin in $admins) { $summary.Add("  - $admin") } }
$summary.Add('')
$summary.Add('USERS / ACCOUNTS')
$summary.Add('----------------')
$summary.Add("Android users/profiles: $userCount")
$summary.Add("Accounts (dumpsys):     $accountCount")
$summary.Add('')
$summary.Add('VPN / DNS / DEBUG')
$summary.Add('-----------------')
$summary.Add("always_on_vpn_app:        $(if ($vpnApp) { $vpnApp } else { '(none)' })")
$summary.Add("private_dns_mode:         $(if ($privateDnsMode) { $privateDnsMode } else { '(unknown)' })")
$summary.Add("private_dns_specifier:    $(if ($privateDnsSpecifier) { $privateDnsSpecifier } else { '(none)' })")
$summary.Add("development_settings_on:  $(if ($devSettings) { $devSettings } else { '(unknown)' })")
$summary.Add("adb_enabled:              $(if ($adbEnabled) { $adbEnabled } else { '(unknown)' })")
$summary.Add('')
$summary.Add('NEXT STEPS')
$summary.Add('----------')
$summary.Add('1. Read every automatic flag above and verify it with the owner.')
$summary.Add('2. MVT analysis runs automatically with -WithMvt (bugreport) or')
$summary.Add('   -WithAndroidqf (androidqf). To rerun manually:')
$summary.Add('     mvt-android check-bugreport bugreport.zip')
$summary.Add('     mvt-android check-androidqf <androidqf.zip>')
$summary.Add('3. For suspicious APKs (apks folder):')
$summary.Add('     apkid <file.apk>')
$summary.Add('     or scan in MobSF / jadx / VirusTotal by SHA-256.')
$summary.Add('4. Audit the phone UI: Play Protect, Device admin apps,')
$summary.Add('   Accessibility, Notification access, User CA certificates,')
$summary.Add('   VPN/Private DNS, Google/Samsung/WhatsApp active sessions.')

$summaryPath = Join-Path $caseDir 'summary.txt'
$summary | Out-File -FilePath $summaryPath -Encoding utf8

$readme = @'
ANDROID TRIAGE CASE FOLDER
==========================

What this is
------------
A manual-review snapshot collected over ADB. It is NOT a full forensic image.
A non-rooted Android device cannot be imaged completely, and a clean result
does not prove the device is clean.

Files
-----
summary.txt              Parsed overview + automatic red flags
getprop.txt              Build properties and integrity flags
packages_thirdparty.txt  Installed user apps + installer + APK path
packages_all.txt         All packages (system + user)
device_policy.txt        Active device administrators
accessibility.txt        Accessibility service state
appops.txt               AppOps grants (background, overlay, install, etc.)
settings_secure.txt      Accessibility / notification listeners / secure settings
settings_global.txt      VPN, Private DNS, developer options, ADB state
settings_system.txt      System settings
users.txt                Android users and profiles
accounts.txt             Accounts registered on the device
processes.txt            Running processes
services.txt             Running services
network.txt              Connectivity/VPN state
dumpsys_package.txt      Full package metadata (install times, permissions)
logcat_tail.txt          Last 5000 log lines
bugreport.zip            ADB bugreport (automatic MVT path)
mvt_results_bugreport/   MVT JSON results from the bugreport
androidqf/               androidqf acquisition (deep mode only)
apks/                    Pulled sideloaded APKs (if -PullApks was used)
apk_hashes.txt           SHA-256 of pulled APKs

MVT (known spyware indicators)
------------------------------
Automatic path used by -WithMvt (bugreport):

    adb bugreport .\bugreport.zip
    mvt-android check-bugreport .\bugreport.zip

Deep path with androidqf (interactive):

    androidqf -serial <serial> -output .\a16_androidqf
    mvt-android check-androidqf .\a16_androidqf\<UUID>.zip

MVT also accepts an extracted androidqf folder instead of the zip.

APK analysis
------------
    pip install apkid
    apkid .\apks\*.apk

MobSF (Docker):
    docker run -it -p 8000:8000 opensecurity/mobile-security-framework-mobsf
    open http://localhost:8000

VirusTotal: search by SHA-256 from apk_hashes.txt instead of uploading
personal APKs.

Manual UI audit (do not skip)
-----------------------------
- Settings -> Security and privacy -> Auto Blocker -> ON
- More security settings -> Device admin apps
- More security settings -> Encryption & credentials -> Trusted credentials -> USER tab
- Apps -> Special access -> Accessibility / Notification access / Display over other apps
- Connections -> VPN and Private DNS
- Play Store -> profile -> Play Protect -> Scan
- Google account -> Security -> Your devices
- Samsung account -> Devices
- WhatsApp -> Linked devices; Telegram -> Devices; Instagram -> Login activity

Red-flag pattern
----------------
An app with NO launcher icon + accessibility access + installer=null +
battery-optimization exemption is textbook stalkerware.

If something is found
---------------------
1. Preserve this folder and screenshots before uninstalling anything.
2. Change Google/Samsung/WhatsApp/bank passwords from a CLEAN device,
   enable 2FA, revoke sessions.
3. Uninstall the app, then factory reset and set up as new.
4. High-risk case: contact Access Now (accessnow.org/help) or
   Amnesty Security Lab (securitylab.amnesty.org).
'@

$readme | Out-File -FilePath (Join-Path $caseDir 'README.txt') -Encoding utf8

# ---------------------------------------------------------------------------
# 6. MVT analysis (bugreport is automatic; androidqf is interactive)
# ---------------------------------------------------------------------------

$mvtPath = $null
$mvtCommand = Get-Command mvt-android -ErrorAction SilentlyContinue
if ($mvtCommand) {
    $mvtPath = $mvtCommand.Source
}
elseif (Test-Path (Join-Path $PSScriptRoot '.venv\Scripts\mvt-android.exe')) {
    $mvtPath = Join-Path $PSScriptRoot '.venv\Scripts\mvt-android.exe'
}

function Invoke-MvtAnalysis {
    param(
        [string]$MvtPath,
        [string]$SubCommand,
        [string]$Target,
        [string]$CaseDir
    )

    if (-not $MvtPath) {
        Write-Host '[!] mvt-android not found. Install with: pip install mvt' -ForegroundColor Yellow
        return
    }

    Write-Step 'Updating MVT indicators'
    try {
        & $MvtPath download-iocs 2>&1 |
            Tee-Object -FilePath (Join-Path $CaseDir 'mvt_iocs.log')
    }
    catch {
        Write-Host "[!] MVT indicator update failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    $resultName = $SubCommand -replace '^check-', ''
    $mvtOut = Join-Path $CaseDir ("mvt_results_$resultName")
    New-Item -ItemType Directory -Force -Path $mvtOut | Out-Null
    Write-Step "Running MVT $SubCommand analysis"
    try {
        & $MvtPath $SubCommand $Target -o $mvtOut 2>&1 |
            Tee-Object -FilePath (Join-Path $CaseDir "mvt_$resultName.log")
    }
    catch {
        Write-Host "[!] MVT failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($WithMvt) {
    $bugreportPath = Join-Path $caseDir 'bugreport.zip'
    if (Test-Path $bugreportPath) { Remove-Item $bugreportPath -Force }

    Write-Step 'Collecting Android bugreport (may take several minutes)'
    Write-Note 'Keep the phone unlocked and connected.'
    try {
        & adb @adbPrefix bugreport $bugreportPath 2>&1 |
            Tee-Object -FilePath (Join-Path $caseDir 'bugreport_run.log')
    }
    catch {
        Write-Host "[!] adb bugreport failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if (Test-Path $bugreportPath) {
        $sizeMb = [math]::Round((Get-Item $bugreportPath).Length / 1MB, 1)
        Write-Ok "Bugreport collected: $bugreportPath ($sizeMb MB)"
        Invoke-MvtAnalysis -MvtPath $mvtPath -SubCommand 'check-bugreport' -Target $bugreportPath -CaseDir $caseDir
    }
    else {
        Write-Host '[!] Bugreport was not created - skipping MVT bugreport analysis.' -ForegroundColor Yellow
    }
}

if ($WithAndroidqf) {
    $androidqf = Get-Command androidqf -ErrorAction SilentlyContinue
    if (-not $androidqf) {
        Write-Host '[!] androidqf not found in PATH - skipping.' -ForegroundColor Yellow
        Write-Note 'Download: https://github.com/mvt-project/androidqf/releases'
    }
    else {
        $androidqfDir = Join-Path $caseDir 'androidqf'
        New-Item -ItemType Directory -Force -Path $androidqfDir | Out-Null
        Write-Step "Running androidqf into $androidqfDir"

        Write-Note 'androidqf 1.8.3 asks questions in this window; answer them when prompted.'
        $aqfArgs = @(
            '-serial', $Serial,
            '-output', $androidqfDir
        )

        $oldSerialEnv = $env:ANDROID_SERIAL
        $env:ANDROID_SERIAL = $Serial
        try {
            & androidqf @aqfArgs 2>&1 |
                Tee-Object -FilePath (Join-Path $caseDir 'androidqf_run.log')
        }
        catch {
            Write-Host "[!] androidqf failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        finally {
            $env:ANDROID_SERIAL = $oldSerialEnv
        }

        # androidqf writes <UUID>.zip; MVT accepts either the zip or a folder.
        $androidqfTarget = $androidqfDir
        $aqfZip = Get-ChildItem -Path $androidqfDir -Filter '*.zip' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($aqfZip) {
            $androidqfTarget = $aqfZip.FullName
            Write-Step "androidqf archive: $androidqfTarget"
        }

        if ($RunMvt) {
            Invoke-MvtAnalysis -MvtPath $mvtPath -SubCommand 'check-androidqf' -Target $androidqfTarget -CaseDir $caseDir
        }
    }
}
elseif ($RunMvt) {
    Write-Host '[!] -RunMvt requires -WithAndroidqf. Use -WithMvt for automatic bugreport analysis.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 7. Console result
# ---------------------------------------------------------------------------

Write-Host ''
Write-Ok "Collection complete: $caseDir"
Write-Host "    Summary: $summaryPath"
Write-Host "    Raw data: $caseDir"

if ($flags.Count -gt 0) {
    Write-Host ''
    Write-Host 'Automatic flags:' -ForegroundColor Yellow
    foreach ($flag in $flags) { Write-Host "  - $flag" -ForegroundColor Yellow }
}
else {
    Write-Host ''
    Write-Ok 'No automatic red flags. Manual review of the collected files is still required.'
}

Write-Note 'Next: read summary.txt, then run the MVT / APK analysis steps in README.txt.'
