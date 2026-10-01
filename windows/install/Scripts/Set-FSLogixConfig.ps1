#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    FSLogix Profile Container configuration on a VDI golden image (Omnissa Horizon Instant Clone). English / Polish.

.DESCRIPTION
    1. Registry HKLM\SOFTWARE\FSLogix\Profiles - dynamic VHDX, SizeInMBs with headroom,
       DeleteLocalProfileWhenVHDShouldApply=1, FlipFlop, no logon with a temporary profile, RedirXMLSourceFolder.
    2. redirections.xml - cache folders (Edge, Chrome, new and classic Teams, Temp, WER, INetCache, CrashDumps,
       RDP/D3D cache) are kept out of the profile container -> smaller VHDX, faster logon.
    3. Local FSLogix groups - the image administrator account is excluded; containers can be limited to chosen
       groups (e.g. students, staff).
    4. Antivirus exclusions (Microsoft Defender) per Microsoft guidance for FSLogix and for the Horizon Agent,
       App Volumes Agent and DEM folders/processes found on the image. When another antivirus is active
       (e.g. Trend Micro) the exclusion list is written to a file for that product's console.
    5. Marker HKLM\SOFTWARE\EMS\VDI-Image\FSLogixConfigVersion - lets VDI-ImageMaint run the script as a "ps1"
       manifest package (Registry detection).

    Idempotent - a repeated run changes only what differs from the configuration. Supports -WhatIf (preview).

.PARAMETER VHDLocations
    Share(s) for the profile containers, e.g. '\\fs01\Profiles$'. Required.
.PARAMETER SizeInMBs
    Maximum VHDX size (dynamic - it takes only as much as the data). Default 30000 (about 30 GB).
.PARAMETER ProfileIncludeGroups
    Groups that get a container (e.g. 'UNIVERSITY\Students'). Empty = Everyone (FSLogix default).
.PARAMETER ProfileExcludeMembers
    Additional accounts/groups without a container (e.g. 'UNIVERSITY\VDI-Admins').
.PARAMETER ExtraExcludes
    Additional paths (relative to the profile) excluded in redirections.xml.
.PARAMETER RoamIdentity
    Roams the Entra ID identity (Microsoft 365 / Teams / OneDrive SSO) - FSLogix 2210 HF3 or newer.
.PARAMETER Language
    auto (UI culture: pl -> Polish, everything else -> English), en, pl.

.EXAMPLE
    .\Set-FSLogixConfig.ps1 -VHDLocations '\\fs01\Profiles$' -WhatIf
.EXAMPLE
    .\Set-FSLogixConfig.ps1 -VHDLocations '\\fs01\Profiles$' -SizeInMBs 30000 `
        -ProfileIncludeGroups 'UNIVERSITY\Students','UNIVERSITY\Staff' -ProfileExcludeMembers 'UNIVERSITY\VDI-Admins'

.NOTES
    Version 1.1.0. Log: C:\ProgramData\VDI-ImageMaint\Logs\FSLogixConfig_<date>.log
    FSLogix registry changes apply from the next logon - on a golden image: Seal + Push Image.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string[]]$VHDLocations,

    [ValidateRange(5000, 200000)]
    [int]$SizeInMBs = 30000,

    [string]$RedirectionsFolder = (Join-Path $env:ProgramData 'FSLogix\Redirections'),
    [string[]]$ExtraExcludes = @(),

    [string[]]$ProfileIncludeGroups = @(),
    [string[]]$ProfileExcludeMembers = @(),
    [switch]$NoExcludeCurrentAdmin,

    [switch]$RoamIdentity,              # Entra ID identity roaming (M365/Teams SSO) - FSLogix 2210 HF3+
    [switch]$SkipAntivirus,
    [switch]$NoVhdExtensionExclusion,   # no global .vhd/.vhdx extension exclusion
    [int]$ConfigVersion = 1,

    [ValidateSet('auto', 'en', 'pl')]
    [string]$Language = 'auto'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# =====================================================================
#  STRINGS (en = primary, pl = secondary; same keys in both)
# =====================================================================
$Strings = @{
    en = @{
        'start'         = 'FSLogix - VDI image configuration | {0} | {1}'
        'frxOk'         = 'FSLogix Apps {0}'
        'frxMissing'    = '{0}\frx.exe not found - FSLogix is not installed; the settings are saved but will not take effect'
        'shares'        = 'Container locations (VHDLocations)'
        'notUnc'        = '  {0} - not a UNC path'
        'shareOk'       = '  {0} - reachable'
        'shareNo'       = '  {0} - not reachable from this account (check DNS and the NTFS/share permissions for users)'
        'registry'      = 'Registry {0}'
        'setTo'         = 'set to ''{0}'''
        'redir'         = 'redirections.xml -> {0}'
        'redirSame'     = '  unchanged ({0} exclusions)'
        'redirWrite'    = 'write {0} exclusions'
        'redirBackup'   = '  backup of the previous version: redirections.xml.bak_{0}'
        'redirSaved'    = '  {0} exclusions saved'
        'groups'        = 'Local FSLogix groups'
        'noGroups'      = '  no FSLogix groups (the FSLogix installer creates them) - skipped'
        'add'           = 'add {0}'
        'removeEveryone'= 'remove Everyone'
        'cannotRead'    = '  {0} : cannot read the members ({1}) - check manually that Everyone was removed'
        'everyoneOut'   = '  - {0} : Everyone (containers only for the chosen groups)'
        'includeSame'   = '  {0} unchanged (Everyone by default)'
        'av'            = 'Antivirus exclusions'
        'avCounts'      = '  paths: {0}, processes: {1}, extensions: {2} (list: {3})'
        'avSkip'        = '  -SkipAntivirus: antivirus settings are not changed'
        'avProducts'    = '  antivirus: {0} | Defender: {1}'
        'avNone'        = 'not detected'
        'avDefNone'     = 'not available'
        'avThirdParty'  = '  {0}: enter the exclusions from {1} in that product''s console (e.g. Apex One / Vision One - policy for the VDI pool)'
        'avDefAll'      = '  Defender: all exclusions already set'
        'avDefAdd'      = 'add exclusions: {0} paths, {1} processes, {2} extensions'
        'avDefAdded'    = '  Defender: added {0} paths, {1} processes, {2} extensions'
        'avDefFailed'   = '  Defender: {0} (Tamper Protection / managed by Intune? - set the exclusions in the policy)'
        'avFileTitle'   = '# AV exclusions for FSLogix / Horizon / App Volumes / DEM'
        'avFilePaths'   = '[Paths / files]'
        'avFileProcs'   = '[Processes]'
        'avFileExts'    = '[Extensions]'
        'summary'       = 'Summary'
        'sumVhdx'       = '  VHDX: dynamic, max {0} MB, {1}'
        'sumRedir'      = '  redirections.xml: {0} exclusions ({1})'
        'sumAv'         = '  AV: {0} paths, {1} processes, {2} extensions'
        'doneWarn'      = 'Finished with warnings: {0}'
        'done'          = 'Finished successfully'
        'next'          = 'Next: test a logon on a clone, then Seal + Push Image. Existing containers keep their data - new exclusions apply from the next logon.'
    }
    pl = @{
        'start'         = 'FSLogix - konfiguracja obrazu VDI | {0} | {1}'
        'frxOk'         = 'FSLogix Apps {0}'
        'frxMissing'    = 'Nie znaleziono {0}\frx.exe - FSLogix nie jest zainstalowany; ustawienia zostaną zapisane, ale nie zadziałają'
        'shares'        = 'Lokalizacje kontenerów (VHDLocations)'
        'notUnc'        = '  {0} - to nie jest ścieżka UNC'
        'shareOk'       = '  {0} - dostępny'
        'shareNo'       = '  {0} - niedostępny z tego konta (sprawdź DNS oraz uprawnienia NTFS i udziału dla użytkowników)'
        'registry'      = 'Rejestr {0}'
        'setTo'         = 'ustaw na ''{0}'''
        'redir'         = 'redirections.xml -> {0}'
        'redirSame'     = '  bez zmian ({0} wykluczeń)'
        'redirWrite'    = 'zapisz {0} wykluczeń'
        'redirBackup'   = '  kopia poprzedniej wersji: redirections.xml.bak_{0}'
        'redirSaved'    = '  zapisano {0} wykluczeń'
        'groups'        = 'Grupy lokalne FSLogix'
        'noGroups'      = '  brak grup FSLogix (tworzy je instalator FSLogix) - pomijam'
        'add'           = 'dodaj {0}'
        'removeEveryone'= 'usuń Everyone'
        'cannotRead'    = '  {0} : nie można odczytać członków ({1}) - sprawdź ręcznie, czy Everyone został usunięty'
        'everyoneOut'   = '  - {0} : Everyone (kontenery tylko dla wskazanych grup)'
        'includeSame'   = '  {0} bez zmian (domyślnie Everyone)'
        'av'            = 'Wykluczenia antywirusa'
        'avCounts'      = '  ścieżki: {0}, procesy: {1}, rozszerzenia: {2} (lista: {3})'
        'avSkip'        = '  -SkipAntivirus: nie zmieniam ustawień antywirusa'
        'avProducts'    = '  antywirus: {0} | Defender: {1}'
        'avNone'        = 'nie wykryto'
        'avDefNone'     = 'niedostępny'
        'avThirdParty'  = '  {0}: wprowadź wykluczenia z pliku {1} w konsoli tego produktu (np. Apex One / Vision One - polityka dla puli VDI)'
        'avDefAll'      = '  Defender: wszystkie wykluczenia już ustawione'
        'avDefAdd'      = 'dodaj wykluczenia: {0} ścieżek, {1} procesów, {2} rozszerzeń'
        'avDefAdded'    = '  Defender: dodano {0} ścieżek, {1} procesów, {2} rozszerzeń'
        'avDefFailed'   = '  Defender: {0} (Tamper Protection / zarządzanie z Intune? - ustaw wykluczenia w polityce)'
        'avFileTitle'   = '# Wykluczenia AV dla FSLogix / Horizon / App Volumes / DEM'
        'avFilePaths'   = '[Ścieżki / pliki]'
        'avFileProcs'   = '[Procesy]'
        'avFileExts'    = '[Rozszerzenia]'
        'summary'       = 'Podsumowanie'
        'sumVhdx'       = '  VHDX: dynamiczny, max {0} MB, {1}'
        'sumRedir'      = '  redirections.xml: {0} wykluczeń ({1})'
        'sumAv'         = '  AV: {0} ścieżek, {1} procesów, {2} rozszerzeń'
        'doneWarn'      = 'Zakończono z ostrzeżeniami: {0}'
        'done'          = 'Zakończono poprawnie'
        'next'          = 'Dalej: test logowania na klonie, potem Seal + Push Image. Stare kontenery zachowują dane - nowe wykluczenia działają od kolejnego logowania.'
    }
}

$Lang = $Language
if ($Lang -eq 'auto') { $Lang = $(if ((Get-UICulture).TwoLetterISOLanguageName -eq 'pl') { 'pl' } else { 'en' }) }

function T {
    param([string]$Key, [object[]]$Arg = @())
    $s = $Strings[$Lang][$Key]
    if (-not $s) { $s = $Strings['en'][$Key] }
    if (-not $s) { return $Key }
    if ($Arg.Count) { return ($s -f $Arg) }
    return $s
}

$LogDir = Join-Path $env:ProgramData 'VDI-ImageMaint\Logs'
# The log and the AV report are written also with -WhatIf (they do not change the system configuration)
New-Item -ItemType Directory -Path $LogDir -Force -WhatIf:$false | Out-Null
$Stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:Warnings = 0

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'STEP')][string]$Level = 'INFO')
    $color = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERR = 'Red'; STEP = 'Cyan' }[$Level]
    if ($Level -eq 'STEP') { Write-Host '' }
    if ($Level -eq 'WARN') { $script:Warnings++ }
    Write-Host ('[{0}] [{1,-4}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $color
}

function Set-Reg {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [string]$Name, $Value, [ValidateSet('DWord', 'String', 'MultiString', 'ExpandString')][string]$Type = 'DWord')
    $cur = $null
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($key) { $cur = $key.GetValue($Name, $null) }
    $same = if ($Type -eq 'MultiString') { ($null -ne $cur) -and ((@($cur) -join '|') -eq (@($Value) -join '|')) } else { "$cur" -eq "$Value" }
    $show = @($Value) -join '; '
    if ($same) { Write-Log ("  = {0,-38} {1}" -f $Name, $show); return }
    if ($PSCmdlet.ShouldProcess("$Path\$Name", (T 'setTo' @($show)))) {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Log ("  + {0,-38} {1}" -f $Name, $show) OK
    }
}

# =====================================================================
#  CONFIGURATION
# =====================================================================
$ProfilesKey = 'HKLM:\SOFTWARE\FSLogix\Profiles'
$FrxApps     = Join-Path $env:ProgramFiles 'FSLogix\Apps'

# Exclusions from the profile container (paths relative to the user profile folder)
$RedirectionExcludes = @(
    # --- general ---
    'AppData\Local\Temp'
    'AppData\Local\CrashDumps'
    'AppData\Local\D3DSCache'
    'AppData\Local\Microsoft\Windows\WER'
    'AppData\Local\Microsoft\Windows\INetCache'
    'AppData\Local\Microsoft\Terminal Server Client\Cache'
    # --- Microsoft Edge ---
    'AppData\Local\Microsoft\Edge\User Data\Default\Cache'
    'AppData\Local\Microsoft\Edge\User Data\Default\Code Cache'
    'AppData\Local\Microsoft\Edge\User Data\Default\GPUCache'
    'AppData\Local\Microsoft\Edge\User Data\Default\Service Worker\CacheStorage'
    'AppData\Local\Microsoft\Edge\User Data\Default\Service Worker\ScriptCache'
    'AppData\Local\Microsoft\Edge\User Data\ShaderCache'
    'AppData\Local\Microsoft\Edge\User Data\GrShaderCache'
    'AppData\Local\Microsoft\Edge\User Data\GraphiteDawnCache'
    'AppData\Local\Microsoft\Edge\User Data\Crashpad'
    # --- Google Chrome ---
    'AppData\Local\Google\Chrome\User Data\Default\Cache'
    'AppData\Local\Google\Chrome\User Data\Default\Code Cache'
    'AppData\Local\Google\Chrome\User Data\Default\GPUCache'
    'AppData\Local\Google\Chrome\User Data\Default\Service Worker\CacheStorage'
    'AppData\Local\Google\Chrome\User Data\Default\Service Worker\ScriptCache'
    'AppData\Local\Google\Chrome\User Data\ShaderCache'
    'AppData\Local\Google\Chrome\User Data\GrShaderCache'
    'AppData\Local\Google\Chrome\User Data\Crashpad'
    # --- new Teams (MSIX) - only the folders recommended by Microsoft; do NOT exclude the whole EBWebView ---
    'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs'
    'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\PerfLogs'
    'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\WebStorage'
    # --- classic Teams (if still present) ---
    'AppData\Roaming\Microsoft\Teams\Cache'
    'AppData\Roaming\Microsoft\Teams\blob_storage'
    'AppData\Roaming\Microsoft\Teams\GPUCache'
    'AppData\Roaming\Microsoft\Teams\Service Worker\CacheStorage'
    'AppData\Roaming\Microsoft\Teams\logs'
    'AppData\Roaming\Microsoft\Teams\media-stack'
    'AppData\Roaming\Microsoft\Teams\tmp'
    # --- OneDrive (only the logs - the OneDrive cache stays in the container) ---
    'AppData\Local\Microsoft\OneDrive\logs'
)

# VDI component folders (added when present on the image)
$VdiFolders = @(
    (Join-Path $env:ProgramFiles 'Omnissa\Horizon\Agent')
    (Join-Path $env:ProgramFiles 'Common Files\Omnissa')
    (Join-Path $env:ProgramFiles 'VMware\VMware View\Agent')
    (Join-Path $env:ProgramFiles 'Common Files\VMware\Remote Experience')
    (Join-Path $env:ProgramFiles 'Omnissa\AppVolumes\Agent')
    (Join-Path $env:ProgramFiles 'CloudVolumes\Agent')
    (Join-Path ${env:ProgramFiles(x86)} 'CloudVolumes\Agent')
    (Join-Path $env:SystemDrive 'SnapVolumesTemp')
    (Join-Path $env:SystemDrive 'SVROOT')
    (Join-Path $env:ProgramFiles 'Omnissa\DEM')
    (Join-Path $env:ProgramFiles 'VMware\Horizon Agents\User Environment Manager')
    (Join-Path $env:ProgramFiles 'Immidio\Flex Profiles')
)
# User session processes (not services) - key for logon time and Blast performance
$VdiUserProcesses = @('FlexEngine.exe', 'FlexDirector*.exe', 'VMBlast*.exe', 'horizon_overlay.exe', 'svservice.exe')
$VdiServicePattern = '(?i)\\Omnissa\\|\\VMware View\\|\\Remote Experience\\|CloudVolumes|AppVolumes|Immidio|\\DEM\\'

# =====================================================================
#  START
# =====================================================================
$log = Join-Path $LogDir "FSLogixConfig_$Stamp.log"
Start-Transcript -Path $log -Force -WhatIf:$false -Confirm:$false | Out-Null
try {
    Write-Log (T 'start' @($env:COMPUTERNAME, [Security.Principal.WindowsIdentity]::GetCurrent().Name)) STEP
    if (Test-Path (Join-Path $FrxApps 'frx.exe')) {
        Write-Log (T 'frxOk' @((Get-Item (Join-Path $FrxApps 'frx.exe')).VersionInfo.ProductVersion)) OK
    } else {
        Write-Log (T 'frxMissing' @($FrxApps)) WARN
    }

    # ---------- 1. Shares ----------
    Write-Log (T 'shares') STEP
    foreach ($loc in $VHDLocations) {
        if ($loc -notmatch '^\\\\') { Write-Log (T 'notUnc' @($loc)) WARN; continue }
        if (Test-Path $loc) { Write-Log (T 'shareOk' @($loc)) OK }
        else { Write-Log (T 'shareNo' @($loc)) WARN }
    }

    # ---------- 2. Profiles registry ----------
    Write-Log (T 'registry' @($ProfilesKey)) STEP
    Set-Reg $ProfilesKey 'Enabled'                              1
    Set-Reg $ProfilesKey 'VHDLocations'                         $VHDLocations 'MultiString'
    Set-Reg $ProfilesKey 'VolumeType'                           'VHDX' 'String'
    Set-Reg $ProfilesKey 'IsDynamic'                            1
    Set-Reg $ProfilesKey 'SizeInMBs'                            $SizeInMBs
    Set-Reg $ProfilesKey 'ProfileType'                          0          # one container per user (read/write)
    Set-Reg $ProfilesKey 'DeleteLocalProfileWhenVHDShouldApply' 1          # removes a local profile that collides with the container
    Set-Reg $ProfilesKey 'FlipFlopProfileDirectoryName'         1          # %username%_%sid% folders - readable on the share
    Set-Reg $ProfilesKey 'PreventLoginWithFailure'              1          # container error = no logon (instead of a local profile)
    Set-Reg $ProfilesKey 'PreventLoginWithTempProfile'          1
    Set-Reg $ProfilesKey 'LockedRetryCount'                     3          # quick reaction to a locked VHDX (session on another clone)
    Set-Reg $ProfilesKey 'LockedRetryInterval'                  15
    Set-Reg $ProfilesKey 'ReAttachRetryCount'                   3
    Set-Reg $ProfilesKey 'ReAttachIntervalSeconds'              15
    Set-Reg $ProfilesKey 'RedirXMLSourceFolder'                 $RedirectionsFolder 'String'
    if ($RoamIdentity) { Set-Reg $ProfilesKey 'RoamIdentity' 1 }

    # ---------- 3. redirections.xml ----------
    Write-Log (T 'redir' @($RedirectionsFolder)) STEP
    $excludes = @($RedirectionExcludes + $ExtraExcludes | Where-Object { $_ } | ForEach-Object { $_.Trim('\') } | Select-Object -Unique)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine("<!-- Generated by Set-FSLogixConfig.ps1 v$ConfigVersion, $(Get-Date -Format 'yyyy-MM-dd HH:mm') -->")
    [void]$sb.AppendLine('<FrxProfileFolderRedirection ExcludeCommonFolders="0">')
    [void]$sb.AppendLine('  <Excludes>')
    foreach ($e in $excludes) { [void]$sb.AppendLine(('    <Exclude Copy="0">{0}</Exclude>' -f [Security.SecurityElement]::Escape($e))) }
    [void]$sb.AppendLine('  </Excludes>')
    [void]$sb.AppendLine('  <Includes>')
    [void]$sb.AppendLine('  </Includes>')
    [void]$sb.AppendLine('</FrxProfileFolderRedirection>')
    $xmlText = $sb.ToString()
    $xmlPath = Join-Path $RedirectionsFolder 'redirections.xml'

    $existing = if (Test-Path $xmlPath) { [IO.File]::ReadAllText($xmlPath) } else { '' }
    # the comment line (date; Polish in files written by 1.0) does not count as a change
    $norm = { param($t) ($t -split "`r?`n" | Where-Object { $_ -notmatch '^<!-- (Generated by|Wygenerowano)' }) -join "`n" }
    if ((& $norm $existing) -eq (& $norm $xmlText)) {
        Write-Log (T 'redirSame' @($excludes.Count))
    } elseif ($PSCmdlet.ShouldProcess($xmlPath, (T 'redirWrite' @($excludes.Count)))) {
        New-Item -ItemType Directory -Path $RedirectionsFolder -Force | Out-Null
        if ($existing) { Copy-Item $xmlPath "$xmlPath.bak_$Stamp" -Force; Write-Log (T 'redirBackup' @($Stamp)) }
        [IO.File]::WriteAllText($xmlPath, $xmlText, (New-Object System.Text.UTF8Encoding($false)))
        [void][xml][IO.File]::ReadAllText($xmlPath)   # syntax check
        Write-Log (T 'redirSaved' @($excludes.Count)) OK
    }

    # ---------- 4. Local FSLogix groups ----------
    Write-Log (T 'groups') STEP
    $exGroup = 'FSLogix Profile Exclude List'
    $inGroup = 'FSLogix Profile Include List'
    if (-not (Get-LocalGroup -Name $exGroup -ErrorAction SilentlyContinue)) {
        Write-Log (T 'noGroups') WARN
    } else {
        $toExclude = @($ProfileExcludeMembers)
        if (-not $NoExcludeCurrentAdmin) { $toExclude += [Security.Principal.WindowsIdentity]::GetCurrent().Name }
        $exMembers = @()
        try { $exMembers = @(Get-LocalGroupMember -Group $exGroup -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { }
        foreach ($m in ($toExclude | Select-Object -Unique)) {
            if ($exMembers -contains $m) { Write-Log "  = $exGroup : $m"; continue }
            if ($PSCmdlet.ShouldProcess($exGroup, (T 'add' @($m)))) {
                try { Add-LocalGroupMember -Group $exGroup -Member $m -ErrorAction Stop; Write-Log "  + $exGroup : $m" OK }
                catch { Write-Log "  $exGroup : $m - $($_.Exception.Message)" WARN }
            }
        }
        if ($ProfileIncludeGroups.Count) {
            $inMembers = @()
            try { $inMembers = @(Get-LocalGroupMember -Group $inGroup -ErrorAction Stop) }
            catch { Write-Log (T 'cannotRead' @($inGroup, $_.Exception.Message)) WARN }
            foreach ($g in $ProfileIncludeGroups) {
                if (@($inMembers | Where-Object { $_.Name -eq $g }).Count) { Write-Log "  = $inGroup : $g"; continue }
                if ($PSCmdlet.ShouldProcess($inGroup, (T 'add' @($g)))) {
                    try { Add-LocalGroupMember -Group $inGroup -Member $g -ErrorAction Stop; Write-Log "  + $inGroup : $g" OK }
                    catch { Write-Log "  $inGroup : $g - $($_.Exception.Message)" WARN }
                }
            }
            $everyone = @($inMembers | Where-Object { $_.SID.Value -eq 'S-1-1-0' })
            if ($everyone.Count -and $PSCmdlet.ShouldProcess($inGroup, (T 'removeEveryone'))) {
                Remove-LocalGroupMember -Group $inGroup -Member (New-Object Security.Principal.SecurityIdentifier 'S-1-1-0')
                Write-Log (T 'everyoneOut' @($inGroup)) OK
            }
        } else {
            Write-Log (T 'includeSame' @($inGroup))
        }
    }

    # ---------- 5. Antivirus exclusions ----------
    $avPaths = New-Object System.Collections.Generic.List[string]
    $avProcs = New-Object System.Collections.Generic.List[string]
    $avExts  = New-Object System.Collections.Generic.List[string]
    # FSLogix per Microsoft documentation
    foreach ($f in 'frxdrv.sys', 'frxdrvvt.sys', 'frxccd.sys') { $avPaths.Add("%ProgramFiles%\FSLogix\Apps\$f") }
    foreach ($ext in 'VHD', 'VHDX') {
        $avPaths.Add("%TEMP%\*.$ext"); $avPaths.Add("%Windir%\TEMP\*.$ext")
        $avPaths.Add("%ProgramData%\FSLogix\Cache\*.$ext"); $avPaths.Add("%ProgramData%\FSLogix\Proxy\*.$ext")
        foreach ($loc in $VHDLocations) {
            $l = $loc.TrimEnd('\')
            foreach ($suffix in '', '.lock', '.meta', '.metadata') { $avPaths.Add("$l\*\*.$ext$suffix") }
        }
    }
    foreach ($p in 'frxccd.exe', 'frxccds.exe', 'frxsvc.exe') { $avProcs.Add("%ProgramFiles%\FSLogix\Apps\$p") }
    if (-not $NoVhdExtensionExclusion) { $avExts.Add('vhd'); $avExts.Add('vhdx') }

    # Horizon / App Volumes / DEM - only what is on the image
    foreach ($d in $VdiFolders) { if ($d -and (Test-Path $d)) { $avPaths.Add($d) } }
    foreach ($svc in @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)) {
        $pn = [string]$svc.PathName
        if ($pn -notmatch $VdiServicePattern) { continue }
        $exe = if ($pn -match '^"([^"]+)"') { $Matches[1] } elseif ($pn -match '^(\S+\.exe)') { $Matches[1] } else { '' }
        if ($exe -and (Test-Path $exe)) { $avProcs.Add($exe) }
    }
    foreach ($d in @($VdiFolders | Where-Object { $_ -and (Test-Path $_) -and $_ -notmatch 'SnapVolumesTemp|SVROOT' })) {
        foreach ($pat in $VdiUserProcesses) {
            Get-ChildItem -Path $d -Recurse -File -Filter $pat -ErrorAction SilentlyContinue | ForEach-Object { $avProcs.Add($_.FullName) }
        }
    }
    $avPaths = @($avPaths | Select-Object -Unique)
    $avProcs = @($avProcs | Select-Object -Unique)
    $avExts  = @($avExts  | Select-Object -Unique)

    $avFile = Join-Path $LogDir "AV-exclusions_$Stamp.txt"
    @((T 'avFileTitle'), "# $env:COMPUTERNAME, $(Get-Date -Format 'yyyy-MM-dd HH:mm')", '',
      (T 'avFilePaths')) + $avPaths + @('', (T 'avFileProcs')) + $avProcs + @('', (T 'avFileExts')) + $avExts |
        Set-Content -Path $avFile -Encoding UTF8 -WhatIf:$false

    Write-Log (T 'av') STEP
    Write-Log (T 'avCounts' @($avPaths.Count, $avProcs.Count, $avExts.Count, $avFile))
    if ($SkipAntivirus) {
        Write-Log (T 'avSkip')
    } else {
        $products = @()
        try { $products = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { $_.displayName }) } catch { }
        $mode = ''
        try { $mode = [string](Get-MpComputerStatus -ErrorAction Stop).AMRunningMode } catch { }
        Write-Log (T 'avProducts' @($(if ($products.Count) { $products -join ', ' } else { T 'avNone' }), $(if ($mode) { $mode } else { T 'avDefNone' })))
        $thirdParty = @($products | Where-Object { $_ -notmatch 'Defender' })
        if ($thirdParty.Count) {
            Write-Log (T 'avThirdParty' @(($thirdParty -join ', '), $avFile)) WARN
        }
        if ($mode) {
            $pref = Get-MpPreference
            $newPaths = @($avPaths | Where-Object { @($pref.ExclusionPath) -notcontains $_ })
            $newProcs = @($avProcs | Where-Object { @($pref.ExclusionProcess) -notcontains $_ })
            $newExts  = @($avExts  | Where-Object { @($pref.ExclusionExtension) -notcontains $_ })
            if (($newPaths.Count + $newProcs.Count + $newExts.Count) -eq 0) {
                Write-Log (T 'avDefAll') OK
            } elseif ($PSCmdlet.ShouldProcess('Microsoft Defender', (T 'avDefAdd' @($newPaths.Count, $newProcs.Count, $newExts.Count)))) {
                try {
                    if ($newPaths.Count) { Add-MpPreference -ExclusionPath $newPaths -ErrorAction Stop }
                    if ($newProcs.Count) { Add-MpPreference -ExclusionProcess $newProcs -ErrorAction Stop }
                    if ($newExts.Count)  { Add-MpPreference -ExclusionExtension $newExts -ErrorAction Stop }
                    Write-Log (T 'avDefAdded' @($newPaths.Count, $newProcs.Count, $newExts.Count)) OK
                } catch {
                    Write-Log (T 'avDefFailed' @($_.Exception.Message)) WARN
                }
            }
        }
    }

    # ---------- 6. Version marker (Registry detection in the VDI-ImageMaint manifest) ----------
    if ($PSCmdlet.ShouldProcess('HKLM:\SOFTWARE\EMS\VDI-Image', "FSLogixConfigVersion=$ConfigVersion")) {
        if (-not (Test-Path 'HKLM:\SOFTWARE\EMS\VDI-Image')) { New-Item 'HKLM:\SOFTWARE\EMS\VDI-Image' -Force | Out-Null }
        New-ItemProperty -Path 'HKLM:\SOFTWARE\EMS\VDI-Image' -Name 'FSLogixConfigVersion' -Value ([string]$ConfigVersion) -PropertyType String -Force | Out-Null
    }

    Write-Log (T 'summary') STEP
    Write-Log (T 'sumVhdx' @($SizeInMBs, ($VHDLocations -join '; ')))
    Write-Log (T 'sumRedir' @($excludes.Count, $xmlPath))
    Write-Log (T 'sumAv' @($avPaths.Count, $avProcs.Count, $avExts.Count))
    if ($script:Warnings) { Write-Log (T 'doneWarn' @($script:Warnings)) WARN } else { Write-Log (T 'done') OK }
    Write-Log (T 'next')
    $exit = 0
} catch {
    Write-Log $_.Exception.Message ERR
    $exit = 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }   # without a transcript (e.g. -WhatIf) Stop-Transcript throws
}
exit $exit
