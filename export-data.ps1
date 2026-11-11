#Requires -Version 5.1
<#
.SYNOPSIS
    Export personal data from a consented Android phone over ADB.

.DESCRIPTION
    Copies what ADB can actually reach without root:
      - shared storage: photos, videos, downloads, documents, recordings
      - WhatsApp media and the latest encrypted local backups
      - Telegram media/files from both known locations
      - logs, dumpsys state and an optional bugreport
      - a best-effort content query for SMS, call log and contacts

    With -Root it also exports app-private data from a phone that is already
    rooted: WhatsApp databases and key, Chrome profile, Telegram cache, the
    SMS/MMS database and the contacts/call-log database.

    It does NOT bypass the Android sandbox. On a non-rooted phone the live
    WhatsApp/Chrome/Telegram databases are not reachable. See
    DATA-EXTRACTION.md for the full truth table and the app-level export routes.

.PARAMETER OutputDir
    Root folder for the export case. Default: .\cases

.PARAMETER Serial
    ADB serial. Auto-detected when exactly one device is ready.

.PARAMETER Preset
    whatsapp, telegram, media, docs, all, logs, root, or custom.
    Default: custom (interactive menu).

.PARAMETER Categories
    Explicit category list. Overrides -Preset. Valid values:
    whatsapp-media, whatsapp-backups, telegram, dcim, pictures, movies,
    downloads, documents, recordings, logs, root.

.PARAMETER WithBugreport
    Also run adb bugreport (5-15 minutes over a remote connection).

.PARAMETER Root
    Export /data/data for the packages in -Packages. Requires a working su.

.PARAMETER Packages
    Packages to export in root mode.

.PARAMETER SkipHash
    Do not compute SHA-256 for every file. Faster, but weaker integrity record.

.PARAMETER Yes
    Skip the consent confirmation. For scripted use only.

.PARAMETER ListOnly
    Show the size of each selected category and exit without copying anything.

.EXAMPLE
    .\export-data.ps1

.EXAMPLE
    .\export-data.ps1 -Preset whatsapp

.EXAMPLE
    .\export-data.ps1 -Preset all -WithBugreport

.EXAMPLE
    .\export-data.ps1 -Root -Packages com.whatsapp,org.telegram.messenger

.NOTES
    Use only on a phone you own or have explicit written permission to examine.
    The case folder contains personal data. Keep it local and gitignored.
#>
[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path (Get-Location) 'cases'),
    [string]$Serial,
    [ValidateSet('custom', 'whatsapp', 'telegram', 'media', 'docs', 'all', 'logs', 'root')]
    [string]$Preset = 'custom',
    [string[]]$Categories,
    [switch]$WithBugreport,
    [switch]$Root,
    [string[]]$Packages = @(
        'com.whatsapp',
        'com.android.chrome',
        'org.telegram.messenger',
        'com.android.providers.telephony',
        'com.android.providers.contacts'
    ),
    [switch]$SkipHash,
    [switch]$Yes,
    [switch]$ListOnly
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Text)
    Write-Host "[*] $Text" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[+] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "[!] $Text" -ForegroundColor Yellow
}

function Write-Note {
    param([string]$Text)
    Write-Host "[i] $Text" -ForegroundColor DarkGray
}

function Stop-WithError {
    param([string]$Text)
    Write-Host ''
    Write-Host "ERROR: $Text" -ForegroundColor Red
    exit 1
}

function Format-Size {
    param([int64]$Kb)
    if ($Kb -lt 0) { return 'unknown' }
    $bytes = $Kb * 1024
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    return ('{0:N0} KB' -f $Kb)
}

# Prefer the adb bundled with this project; fall back to one in PATH.
$Adb = $null
$localAdb = Join-Path $PSScriptRoot 'tools\platform-tools\adb.exe'
if (Test-Path $localAdb) {
    $Adb = $localAdb
}
else {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { $Adb = $cmd.Source }
}
if (-not $Adb) {
    Stop-WithError 'adb was not found. Run START-HERE.bat once to install the local tools, or add platform-tools to PATH.'
}

function Get-Devices {
    $result = @()
    $lines = @(& $Adb devices 2>&1)
    foreach ($line in $lines) {
        if ($line -match '^(\S+)\s+(device|unauthorized|offline)\s*$') {
            $result += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2] }
        }
    }
    return $result
}

function Get-RemoteSizeKb {
    param([string]$Remote)
    $output = & $Adb -s $Serial shell "du -sk '$Remote' 2>/dev/null" 2>$null
    foreach ($line in @($output)) {
        if ("$line" -match '^\s*(\d+)\s+') { return [int64]$Matches[1] }
    }
    return [int64]-1
}

function Get-RootSizeKb {
    param([string]$Remote)
    $output = & $Adb -s $Serial shell "su -c 'du -sk $Remote' 2>/dev/null" 2>$null
    foreach ($line in @($output)) {
        if ("$line" -match '^\s*(\d+)\s+') { return [int64]$Matches[1] }
    }
    return [int64]-1
}

function Get-DeviceFreeKb {
    $output = & $Adb -s $Serial shell "df -k /data 2>/dev/null" 2>$null
    foreach ($line in @($output)) {
        if ("$line" -match '^\S+\s+\d+\s+\d+\s+(\d+)\s+\d+%') {
            return [int64]$Matches[1]
        }
    }
    return [int64]-1
}

function Get-LatestBackups {
    param([string]$Remote, [int]$Count)
    $output = & $Adb -s $Serial shell "ls -lt '$Remote' 2>/dev/null" 2>$null
    $files = @()
    foreach ($line in @($output)) {
        $text = "$line".Trim()
        if ($text -match '(\S+\.crypt\d+)\s*$') { $files += $Matches[1] }
    }
    return @($files | Select-Object -First $Count)
}

function Invoke-PullPath {
    param(
        [string]$Remote,
        [string]$Local,
        [switch]$IsFile
    )

    $parent = Split-Path -Parent $Local
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    if ($IsFile) {
        $source = $Remote
    }
    else {
        New-Item -ItemType Directory -Force -Path $Local | Out-Null
        $source = "$Remote/."
    }

    "adb -s $Serial pull `"$source`" `"$Local`"" |
        Out-File -FilePath $commandsLog -Append -Encoding utf8

    $output = & $Adb -s $Serial pull $source $Local 2>&1
    $output | Out-File -FilePath (Join-Path $caseDir 'pull.log') -Append -Encoding utf8

    if ($LASTEXITCODE -ne 0) {
        Write-Warn "pull failed: $Remote (exit $LASTEXITCODE)"
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
# Device selection
# ---------------------------------------------------------------------------

$devices = @(Get-Devices)
if ($Serial) {
    $match = $devices | Where-Object { $_.Serial -eq $Serial } | Select-Object -First 1
    if (-not $match -or $match.State -ne 'device') {
        Stop-WithError "Device '$Serial' is not ready. Check USB debugging / wireless debugging and run: adb devices"
    }
}
else {
    $ready = @($devices | Where-Object { $_.State -eq 'device' })
    if ($ready.Count -eq 0) {
        $unauthorized = @($devices | Where-Object { $_.State -eq 'unauthorized' })
        if ($unauthorized.Count -gt 0) {
            Stop-WithError "Device is unauthorized. Unlock the phone and tap 'Allow USB debugging', then retry."
        }
        Stop-WithError 'No authorized device found. Connect by USB or wireless debugging first.'
    }
    if ($ready.Count -eq 1) {
        $Serial = $ready[0].Serial
    }
    else {
        Write-Host 'Multiple devices are connected:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $ready.Count; $i++) {
            Write-Host ("  {0}) {1}" -f ($i + 1), $ready[$i].Serial)
        }
        $pick = Read-Host 'Choose device'
        $index = 0
        if (-not [int]::TryParse($pick, [ref]$index)) { Stop-WithError 'Invalid device choice.' }
        $index = $index - 1
        if ($index -lt 0 -or $index -ge $ready.Count) { Stop-WithError 'Invalid device choice.' }
        $Serial = $ready[$index].Serial
    }
}
Write-Ok "Using device: $Serial"

# ---------------------------------------------------------------------------
# Categories
# ---------------------------------------------------------------------------

$catalog = [ordered]@{
    'whatsapp-media' = [pscustomobject]@{
        Label = 'WhatsApp media (photos, video, audio, documents)'
        Items = @(
            [pscustomobject]@{ Remote = '/sdcard/Android/media/com.whatsapp/WhatsApp/Media'; Local = 'shared\whatsapp\Media' }
        )
    }
    'whatsapp-backups' = [pscustomobject]@{
        Label = 'WhatsApp encrypted local backups (latest 2)'
        Items = @(
            [pscustomobject]@{ Remote = '/sdcard/Android/media/com.whatsapp/WhatsApp/Databases'; Local = 'shared\whatsapp\Databases'; Latest = 2 }
        )
    }
    'telegram' = [pscustomobject]@{
        Label = 'Telegram media and files (shared storage)'
        Items = @(
            [pscustomobject]@{ Remote = '/sdcard/Android/media/org.telegram.messenger/Telegram'; Local = 'shared\telegram\android-media' },
            [pscustomobject]@{ Remote = '/sdcard/Telegram'; Local = 'shared\telegram\sdcard'; Optional = $true }
        )
    }
    'dcim' = [pscustomobject]@{
        Label = 'Photos and videos (DCIM)'
        Items = @(
            [pscustomobject]@{ Remote = '/sdcard/DCIM'; Local = 'shared\DCIM' }
        )
    }
    'pictures' = [pscustomobject]@{
        Label = 'Pictures and screenshots'
        Items = @(
            [pscustomobject]@{ Remote = '/sdcard/Pictures'; Local = 'shared\Pictures' }
        )
    }
    'movies' = [pscustomobject]@{
        Label = 'Movies'
        Items = @(
            [pscustomobject]@{ Remote = '/sdcard/Movies'; Local = 'shared\Movies' }
        )
    }
    'downloads' = [pscustomobject]@{
        Label = 'Downloads'
        Items = @(
            [pscustomobject]@{ Remote = '/sdcard/Download'; Local = 'shared\Download' }
        )
    }
    'documents' = [pscustomobject]@{
        Label = 'Documents'
        Items = @(
            [pscustomobject]@{ Remote = '/sdcard/Documents'; Local = 'shared\Documents' }
        )
    }
    'recordings' = [pscustomobject]@{
        Label = 'Call recordings / voice recordings'
        Items = @(
            [pscustomobject]@{ Remote = '/sdcard/Recordings'; Local = 'shared\Recordings'; Optional = $true },
            [pscustomobject]@{ Remote = '/sdcard/Music/Recordings'; Local = 'shared\Music-Recordings'; Optional = $true }
        )
    }
    'logs' = [pscustomobject]@{
        Label = 'Logs and system state'
        Items = @()
    }
    'root' = [pscustomobject]@{
        Label = 'App-private data via root'
        Items = @()
    }
}

$presetMap = @{
    'whatsapp' = @('whatsapp-media', 'whatsapp-backups')
    'telegram' = @('telegram')
    'media'    = @('dcim', 'pictures', 'movies')
    'docs'     = @('downloads', 'documents', 'recordings')
    'all'      = @('whatsapp-media', 'whatsapp-backups', 'telegram', 'dcim', 'pictures', 'movies', 'downloads', 'documents', 'recordings')
    'logs'     = @()
    'root'     = @()
    'custom'   = @()
}

function Show-ExportMenu {
    Write-Host ''
    Write-Host 'What do you want to export?' -ForegroundColor Cyan
    Write-Host '  1) WhatsApp media + latest encrypted backups'
    Write-Host '  2) Telegram media and files'
    Write-Host '  3) Photos and videos (DCIM, Pictures, Movies)'
    Write-Host '  4) Downloads, Documents, Recordings'
    Write-Host '  5) Everything shared + logs (can be tens of GB)'
    Write-Host '  6) Logs and system state only'
    Write-Host '  7) Root app data (phone must already be rooted)'
    Write-Host '  8) Custom selection'
    Write-Host '  0) Cancel'
    $choice = Read-Host 'Choose [5]'
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '5' }

    switch ($choice) {
        '1' { return @{ Categories = @('whatsapp-media', 'whatsapp-backups'); Logs = $false; Root = $false } }
        '2' { return @{ Categories = @('telegram'); Logs = $false; Root = $false } }
        '3' { return @{ Categories = @('dcim', 'pictures', 'movies'); Logs = $false; Root = $false } }
        '4' { return @{ Categories = @('downloads', 'documents', 'recordings'); Logs = $false; Root = $false } }
        '5' { return @{ Categories = @('whatsapp-media', 'whatsapp-backups', 'telegram', 'dcim', 'pictures', 'movies', 'downloads', 'documents', 'recordings'); Logs = $true; Root = $false } }
        '6' { return @{ Categories = @(); Logs = $true; Root = $false } }
        '7' { return @{ Categories = @(); Logs = $false; Root = $true } }
        '8' {
            $keys = @($catalog.Keys | Where-Object { $_ -ne 'logs' -and $_ -ne 'root' })
            Write-Host ''
            for ($i = 0; $i -lt $keys.Count; $i++) {
                Write-Host ("  {0}) {1} - {2}" -f ($i + 1), $keys[$i], $catalog[$keys[$i]].Label)
            }
            $raw = Read-Host 'Enter numbers separated by commas (blank = cancel)'
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            $picked = @()
            foreach ($part in ($raw -split ',')) {
                $n = 0
                if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $keys.Count) {
                    $picked += $keys[$n - 1]
                }
            }
            if ($picked.Count -eq 0) { return $null }
            $doLogs = (Read-Host 'Include logs and system state? [y/N]') -match '^(y|yes)$'
            $doRoot = (Read-Host 'Include root app data? [y/N]') -match '^(y|yes)$'
            return @{ Categories = $picked; Logs = [bool]$doLogs; Root = [bool]$doRoot }
        }
        '0' { return $null }
        default { Write-Warn 'Invalid choice.'; return $null }
    }
}

$includeLogs = $false
$selected = @()

if ($Categories -and $Categories.Count -gt 0) {
    $selected = @($Categories | ForEach-Object { $_.ToLower().Trim() } | Where-Object { $_ })
    if ($selected -contains 'logs') {
        $includeLogs = $true
        $selected = @($selected | Where-Object { $_ -ne 'logs' })
    }
    if ($selected -contains 'root') {
        $Root = $true
        $selected = @($selected | Where-Object { $_ -ne 'root' })
    }
}
elseif ($Preset -ne 'custom') {
    $selected = @($presetMap[$Preset])
    if ($Preset -eq 'all' -or $Preset -eq 'logs') { $includeLogs = $true }
    if ($Preset -eq 'root') { $Root = $true }
}
else {
    $selection = Show-ExportMenu
    if (-not $selection) {
        Write-Host 'Cancelled.'
        exit 0
    }
    $selected = @($selection.Categories)
    $includeLogs = [bool]$selection.Logs
    if ($selection.Root) { $Root = $true }
}

$selected = @($selected | Select-Object -Unique)
foreach ($key in $selected) {
    if (-not $catalog.Contains($key)) {
        Stop-WithError "Unknown category '$key'. Valid: $($catalog.Keys -join ', ')"
    }
}

# A bugreport lives under logs, so asking for one implies the logs bundle.
if ($WithBugreport) { $includeLogs = $true }

if ($selected.Count -eq 0 -and -not $includeLogs -and -not $Root) {
    Write-Warn 'Nothing selected.'
    exit 0
}

# ---------------------------------------------------------------------------
# Size preview
# ---------------------------------------------------------------------------

function Show-SelectionSizes {
    $totalKb = [int64]0
    foreach ($key in $selected) {
        $cat = $catalog[$key]
        Write-Head $cat.Label
        foreach ($item in $cat.Items) {
            if ($item.PSObject.Properties.Name -contains 'Latest' -and $item.Latest -gt 0) {
                $files = @(Get-LatestBackups -Remote $item.Remote -Count $item.Latest)
                if ($files.Count -eq 0) {
                    Write-Warn "no backups found in $($item.Remote)"
                    continue
                }
                foreach ($file in $files) {
                    $size = Get-RemoteSizeKb -Remote "$($item.Remote)/$file"
                    Write-Host ("  {0}  {1}" -f (Format-Size $size), $file)
                    if ($size -gt 0) { $totalKb += $size }
                }
            }
            else {
                $size = Get-RemoteSizeKb -Remote $item.Remote
                if ($size -lt 0) {
                    if ($item.PSObject.Properties.Name -contains 'Optional' -and $item.Optional) {
                        Write-Note "not present: $($item.Remote)"
                    }
                    else {
                        Write-Warn "not found or not readable: $($item.Remote)"
                    }
                }
                else {
                    Write-Host ("  {0}  {1}" -f (Format-Size $size), $item.Remote)
                    $totalKb += $size
                }
            }
        }
    }

    if ($includeLogs) {
        Write-Head 'Logs and system state'
        Write-Host '  small (a bugreport adds 5-15 minutes and a large ZIP)'
    }

    if ($Root) {
        Write-Head 'App-private data (root)'
        $rootCheck = (& $Adb -s $Serial shell "su -c id" 2>&1 | Out-String).Trim()
        if ($rootCheck -notmatch 'uid=0') {
            Write-Warn 'su is not available; root export would be skipped.'
        }
        else {
            foreach ($pkg in ($Packages | Select-Object -Unique)) {
                $size = Get-RootSizeKb -Remote "/data/data/$pkg"
                Write-Host ("  {0}  /data/data/{1}" -f (Format-Size $size), $pkg)
                if ($size -gt 0) { $totalKb += $size }
            }
        }
    }

    Write-Host ''
    Write-Host ("Estimated total: {0}" -f (Format-Size $totalKb)) -ForegroundColor Cyan
    $qualifier = Split-Path -Qualifier $OutputDir -ErrorAction SilentlyContinue
    if ($qualifier) {
        $drive = Get-PSDrive -Name $qualifier.TrimEnd(':') -ErrorAction SilentlyContinue
        if ($drive) {
            Write-Host ("Free on output drive: {0}" -f (Format-Size ([int64]($drive.Free / 1KB)))) -ForegroundColor DarkGray
        }
    }
}

if ($ListOnly) {
    Show-SelectionSizes
    exit 0
}

# ---------------------------------------------------------------------------
# Consent and case folder
# ---------------------------------------------------------------------------

if (-not $Yes) {
    Write-Host ''
    Write-Host 'This copies personal data to this PC: messages, photos, contacts, logs.' -ForegroundColor Yellow
    Write-Host 'Keep the case folder private. Use only with the owner''s consent.' -ForegroundColor Yellow
    $answer = Read-Host 'Type YES to continue'
    if ($answer -ne 'YES') {
        Write-Host 'Cancelled.'
        exit 0
    }
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$caseDir = Join-Path $OutputDir "export_$stamp"
$logsDir = Join-Path $caseDir 'logs'
$contentDir = Join-Path $logsDir 'content'
New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
New-Item -ItemType Directory -Force -Path $contentDir | Out-Null

$commandsLog = Join-Path $caseDir 'commands.log'
"Android data export - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" |
    Out-File -FilePath $commandsLog -Encoding utf8
"Device: $Serial" | Out-File -FilePath $commandsLog -Append -Encoding utf8
Write-Ok "Case folder: $caseDir"
if ($caseDir -match 'OneDrive') {
    Write-Warn 'The case folder is inside OneDrive. Pause sync or move -OutputDir outside OneDrive if that matters.'
}

$failures = @()
$contentErrors = @()
$exportedLabels = @()

# ---------------------------------------------------------------------------
# Shared storage
# ---------------------------------------------------------------------------

foreach ($key in $selected) {
    $cat = $catalog[$key]
    Write-Head $cat.Label
    $exportedLabels += $cat.Label

    foreach ($item in $cat.Items) {
        $localBase = Join-Path $caseDir $item.Local

        if ($item.PSObject.Properties.Name -contains 'Latest' -and $item.Latest -gt 0) {
            $files = @(Get-LatestBackups -Remote $item.Remote -Count $item.Latest)
            if ($files.Count -eq 0) {
                Write-Warn "no backups found in $($item.Remote)"
                $failures += "$key : no backups in $($item.Remote)"
                continue
            }
            foreach ($file in $files) {
                New-Item -ItemType Directory -Force -Path $localBase | Out-Null
                $remoteFile = "$($item.Remote)/$file"
                $localFile = Join-Path $localBase $file
                $size = Get-RemoteSizeKb -Remote $remoteFile
                Write-Step ("{0}  {1}" -f (Format-Size $size), $file)
                if (-not (Invoke-PullPath -Remote $remoteFile -Local $localFile -IsFile)) {
                    $failures += "$key : $file"
                }
            }
            continue
        }

        $size = Get-RemoteSizeKb -Remote $item.Remote
        if ($size -lt 0) {
            if ($item.PSObject.Properties.Name -contains 'Optional' -and $item.Optional) {
                Write-Note "not present: $($item.Remote)"
            }
            else {
                Write-Warn "not found or not readable: $($item.Remote)"
                $failures += "$key : $($item.Remote) not readable"
            }
            continue
        }

        Write-Step ("{0}  {1}" -f (Format-Size $size), $item.Remote)
        if (-not (Invoke-PullPath -Remote $item.Remote -Local $localBase)) {
            $failures += "$key : $($item.Remote)"
        }
    }
}

# ---------------------------------------------------------------------------
# Logs and system state
# ---------------------------------------------------------------------------

function Invoke-ContentQuery {
    param(
        [string]$Name,
        [string]$Uri,
        [string]$Projection
    )

    $remoteCmd = "content query --uri '$Uri' --projection '$Projection'"
    "adb -s $Serial shell $remoteCmd" |
        Out-File -FilePath $commandsLog -Append -Encoding utf8

    $output = & $Adb -s $Serial shell $remoteCmd 2>&1 | Out-String -Width 8192
    $path = Join-Path $contentDir $Name
    $output | Out-File -FilePath $path -Encoding utf8

    if ($output -match 'Permission Denial|requires android\.permission|SecurityException|Error:') {
        $firstLine = ($output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        $script:contentErrors += "$Name : $firstLine"
        Write-Warn "content query denied: $Name (see logs\content\content_errors.txt)"
    }
    else {
        Write-Ok "content query saved: $Name"
    }
}

if ($includeLogs) {
    Write-Head 'Logs and system state'
    $exportedLabels += 'Logs and system state'

    $logItems = [ordered]@{
        'logcat_all.txt'          = @('logcat', '-d', '-b', 'all', '-t', '20000', '-v', 'threadtime')
        'notifications.txt'       = @('shell', 'dumpsys', 'notification', '--noredact')
        'usagestats.txt'          = @('shell', 'dumpsys', 'usagestats')
        'accounts.txt'            = @('shell', 'dumpsys', 'account')
        'wifi.txt'                = @('shell', 'dumpsys', 'wifi')
        'recents.txt'             = @('shell', 'dumpsys', 'activity', 'recents')
        'device_info.txt'         = @('shell', 'getprop')
        'packages_thirdparty.txt' = @('shell', 'pm', 'list', 'packages', '-3', '-f', '-i')
        'accessibility.txt'       = @('shell', 'dumpsys', 'accessibility')
        'device_policy.txt'       = @('shell', 'dumpsys', 'device_policy')
        'settings_secure.txt'     = @('shell', 'settings', 'list', 'secure')
        'settings_global.txt'     = @('shell', 'settings', 'list', 'global')
    }

    foreach ($name in $logItems.Keys) {
        Write-Step "collecting $name"
        $adbArgs = @('-s', $Serial) + $logItems[$name]
        "adb $($adbArgs -join ' ')" | Out-File -FilePath $commandsLog -Append -Encoding utf8
        & $Adb @adbArgs 2>&1 | Out-File -FilePath (Join-Path $logsDir $name) -Encoding utf8
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "command failed: $name"
            $failures += "logs : $name"
        }
    }

    Write-Step 'collecting content provider queries (SMS, call log, contacts)'
    Invoke-ContentQuery -Name 'sms.txt' -Uri 'content://sms' -Projection '_id,thread_id,address,date,date_sent,type,body,read,seen'
    Invoke-ContentQuery -Name 'call_log.txt' -Uri 'content://call_log/calls' -Projection '_id,number,date,duration,type,name,geocoded_location'
    Invoke-ContentQuery -Name 'contacts.txt' -Uri 'content://com.android.contacts/contacts' -Projection '_id,display_name,has_phone_number,lookup'
    Invoke-ContentQuery -Name 'contacts_data.txt' -Uri 'content://com.android.contacts/data' -Projection '_id,contact_id,mimetype,data1,data2,data3'

    if ($contentErrors.Count -gt 0) {
        $contentErrors | Out-File -FilePath (Join-Path $contentDir 'content_errors.txt') -Encoding utf8
    }

    if ($WithBugreport) {
        Write-Step 'collecting adb bugreport (5-15 minutes)'
        $bugPath = Join-Path $logsDir 'bugreport.zip'
        "adb -s $Serial bugreport $bugPath" | Out-File -FilePath $commandsLog -Append -Encoding utf8
        & $Adb -s $Serial bugreport $bugPath 2>&1 |
            Tee-Object -FilePath (Join-Path $logsDir 'bugreport_run.log') -Append
        if ($LASTEXITCODE -ne 0) {
            Write-Warn 'bugreport failed or was interrupted'
            $failures += 'logs : bugreport'
        }
    }
}

# ---------------------------------------------------------------------------
# Root app data
# ---------------------------------------------------------------------------

if ($Root) {
    Write-Head 'App-private data (root)'
    $exportedLabels += 'App-private data (root)'
    $rootCheck = (& $Adb -s $Serial shell "su -c id" 2>&1 | Out-String).Trim()

    if ($rootCheck -notmatch 'uid=0') {
        Write-Warn 'su is not available on this phone. Root export skipped.'
        Write-Note 'See DATA-EXTRACTION.md section 3 for the root path and its risks.'
        $failures += 'root : su not available'
    }
    else {
        Write-Ok 'Root available.'
        $appdataDir = Join-Path $caseDir 'appdata'
        New-Item -ItemType Directory -Force -Path $appdataDir | Out-Null
        $rootHashes = New-Object System.Collections.Generic.List[string]

        foreach ($pkg in ($Packages | Select-Object -Unique)) {
            Write-Step "exporting /data/data/$pkg"
            $exists = (& $Adb -s $Serial shell "su -c '[ -d /data/data/$pkg ] && echo yes || echo no'" | Out-String).Trim()
            if ($exists -ne 'yes') {
                Write-Warn "not found: $pkg"
                $failures += "root : $pkg not found"
                continue
            }

            $safe = $pkg -replace '[^A-Za-z0-9_.-]', '_'
            $remoteTar = "/data/local/tmp/triage_$safe.tar"
            $localTar = Join-Path $appdataDir "$safe.tar"

            if ($pkg -notlike 'com.android.providers.*') {
                & $Adb -s $Serial shell "su -c 'am force-stop $pkg'" 2>&1 | Out-Null
            }

            $pkgKb = Get-RootSizeKb -Remote "/data/data/$pkg"
            $freeKb = Get-DeviceFreeKb
            if ($pkgKb -gt 0 -and $freeKb -gt 0 -and $pkgKb -gt ($freeKb - 524288)) {
                Write-Warn ("not enough free space on /data for $pkg ({0} needed, {1} free)" -f (Format-Size $pkgKb), (Format-Size $freeKb))
                $failures += "root : $pkg needs more free space"
                continue
            }

            $tarCmd = "su -c 'tar -cf $remoteTar -C /data/data $pkg'"
            "adb -s $Serial shell $tarCmd" | Out-File -FilePath $commandsLog -Append -Encoding utf8
            $tarOut = & $Adb -s $Serial shell $tarCmd 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "tar failed: $pkg"
                if ($tarOut) { Write-Note (($tarOut | Out-String).Trim()) }
                & $Adb -s $Serial shell "su -c 'rm -f $remoteTar'" 2>&1 | Out-Null
                $failures += "root : tar $pkg"
                continue
            }

            & $Adb -s $Serial shell "su -c 'chmod 644 $remoteTar'" 2>&1 | Out-Null
            $pulled = Invoke-PullPath -Remote $remoteTar -Local $localTar -IsFile
            & $Adb -s $Serial shell "su -c 'rm -f $remoteTar'" 2>&1 | Out-Null

            if (-not $pulled) {
                $failures += "root : pull $pkg"
                continue
            }

            if (-not $SkipHash) {
                $hash = Get-FileHash -LiteralPath $localTar -Algorithm SHA256
                $rootHashes.Add(('{0}  {1}' -f $hash.Hash, (Split-Path $localTar -Leaf)))
            }

            Write-Step "extracting $pkg"
            & tar -xf $localTar -C $appdataDir 2>&1 |
                Out-File -FilePath (Join-Path $logsDir 'tar_extract.log') -Append
            if ($LASTEXITCODE -eq 0) {
                Remove-Item -LiteralPath $localTar -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-Warn "extract failed; tar left at $localTar"
                $failures += "root : extract $pkg"
            }
        }

        if ($rootHashes.Count -gt 0) {
            $rootHashes | Out-File -FilePath (Join-Path $appdataDir 'appdata_hashes.txt') -Encoding utf8
        }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

$model = (& $Adb -s $Serial shell getprop ro.product.model 2>$null | Out-String).Trim()
$android = (& $Adb -s $Serial shell getprop ro.build.version.release 2>$null | Out-String).Trim()
$patch = (& $Adb -s $Serial shell getprop ro.build.version.security_patch 2>$null | Out-String).Trim()

$report = New-Object System.Collections.Generic.List[string]
$report.Add('ANDROID DATA EXPORT')
$report.Add('===================')
$report.Add('')
$report.Add("Device:        $model")
$report.Add("Android:       $android")
$report.Add("Patch level:   $patch")
$report.Add("Serial:        $Serial")
$report.Add("Exported:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$report.Add("Case folder:   $caseDir")
$report.Add('')
$report.Add('WHAT WAS EXPORTED')
$report.Add('------------------')
foreach ($label in $exportedLabels) { $report.Add("- $label") }
if ($WithBugreport) {
    if (Test-Path (Join-Path $logsDir 'bugreport.zip')) {
        $report.Add('- adb bugreport (logs\bugreport.zip)')
    }
    else {
        $report.Add('- adb bugreport was requested but not produced')
    }
}
if ($exportedLabels.Count -eq 0) { $report.Add('- (nothing)') }
$report.Add('')
$report.Add('WHAT FAILED OR WAS SKIPPED')
$report.Add('---------------------------')
if ($failures.Count -eq 0) {
    $report.Add('- none')
}
else {
    foreach ($failure in $failures) { $report.Add("- $failure") }
}
$report.Add('')
$report.Add('WHAT IS STILL MISSING, AND HOW TO GET IT')
$report.Add('-----------------------------------------')
$report.Add('- WhatsApp live messages: in-app Export chat, or root (DATA-EXTRACTION.md 2.2/3)')
$report.Add('- WhatsApp crypt14 key: /data/data/com.whatsapp/files/key - root only')
$report.Add('- Chrome History: Google Takeout, or root')
$report.Add('- Chrome cookies: root + Frida/Keystore, or a commercial forensic tool')
$report.Add('- Chrome saved passwords: Google Password Manager, or root + OSCrypt')
$report.Add('- Telegram live cache: in-app Export Telegram data, or root')
$report.Add('- SMS / call log: exporter app, or root (mmssms.db / contacts2.db)')
$report.Add('- Contacts: Contacts app -> Export to storage (.vcf), or root')
$report.Add('- Wi-Fi passwords, Keystore secrets, app tokens: root, and some are non-exportable')
$report.Add('')
$report.Add('HOW TO OPEN THE FILES')
$report.Add('---------------------')
$report.Add('- manifest.csv: path, size and SHA-256 for every exported file')
$report.Add('- SQLite databases: DB Browser for SQLite (https://sqlitebrowser.org/)')
$report.Add('- WhatsApp .crypt14: needs the key file; use wa-crypt-tools wadecrypt')
$report.Add('- WhatsApp .crypt15: 64-digit key; wa-crypt-tools wadecrypt')
$report.Add('- Telegram export: result.json (JSON) or messages.html (HTML)')
$report.Add('')
$report.Add('SECURITY AND RETENTION')
$report.Add('----------------------')
$report.Add('- This folder contains personal data. Keep it local and encrypted.')
$report.Add('- cases\ is gitignored; do not move this folder into a public repo.')
$report.Add('- If the repo is inside OneDrive, pause sync or move the case outside OneDrive.')
$report.Add('- Delete the folder securely when it is no longer needed.')
$report.Add('')
$report.Add('See DATA-EXTRACTION.md for the full guide and the root/commercial options.')
$report | Out-File -FilePath (Join-Path $caseDir 'EXPORT-README.txt') -Encoding utf8

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

Write-Step 'building manifest (SHA-256 can take a while on large media)'
$files = @(Get-ChildItem -LiteralPath $caseDir -Recurse -File -ErrorAction SilentlyContinue)
$rows = New-Object System.Collections.Generic.List[object]
foreach ($file in $files) {
    if ($file.Name -eq 'manifest.csv') { continue }
    $hash = ''
    if (-not $SkipHash) {
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    $relative = $file.FullName.Substring($caseDir.Length).TrimStart('\')
    $rows.Add([pscustomobject]@{
        RelativePath = $relative
        SizeBytes    = $file.Length
        SHA256       = $hash
    })
}

if ($rows.Count -gt 0) {
    $rows | Export-Csv -Path (Join-Path $caseDir 'manifest.csv') -NoTypeInformation -Encoding UTF8
}
else {
    'No files were exported.' | Out-File -FilePath (Join-Path $caseDir 'manifest.csv') -Encoding utf8
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Head 'Done'
Write-Ok "Case folder: $caseDir"
Write-Ok "Report:      $(Join-Path $caseDir 'EXPORT-README.txt')"
Write-Ok "Manifest:    $(Join-Path $caseDir 'manifest.csv')"
if ($failures.Count -gt 0) {
    Write-Warn "$($failures.Count) item(s) failed or were skipped. See EXPORT-README.txt."
}
Write-Note 'Keep the case folder private. See DATA-EXTRACTION.md for what still needs root or a forensic tool.'
exit 0
