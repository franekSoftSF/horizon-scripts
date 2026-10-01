#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Konfiguracja FSLogix Profile Container na złotym obrazie VDI (Omnissa Horizon Instant Clone).

.DESCRIPTION
    1. Rejestr HKLM\SOFTWARE\FSLogix\Profiles - VHDX dynamiczny, SizeInMBs z zapasem,
       DeleteLocalProfileWhenVHDShouldApply=1, FlipFlop, blokada logowania na profil tymczasowy,
       RedirXMLSourceFolder.
    2. redirections.xml - wykluczenia cache (Edge, Chrome, nowy i klasyczny Teams, Temp, WER,
       INetCache, CrashDumps, cache RDP/D3D) z kontenera profilu -> mniejszy VHDX, szybsze logowanie.
    3. Grupy lokalne FSLogix - wykluczenie konta administracyjnego obrazu, opcjonalnie ograniczenie
       kontenerów do wskazanych grup (np. studenci, pracownicy).
    4. Wykluczenia antywirusa (Microsoft Defender) wg zaleceń Microsoft dla FSLogix oraz dla
       folderów/procesów Horizon Agent, App Volumes Agent i DEM (wykrywanych na obrazie).
       Gdy aktywny jest inny antywirus (np. Trend Micro), lista wykluczeń jest zapisywana do pliku
       do wprowadzenia w konsoli tego produktu.
    5. Znacznik HKLM\SOFTWARE\EMS\VDI-Image\FSLogixConfigVersion - pozwala uruchamiać skrypt jako
       pakiet "ps1" z manifestu VDI-ImageMaint (detekcja Registry).

    Skrypt jest idempotentny - ponowne uruchomienie zmienia tylko to, co odbiega od konfiguracji.
    Obsługuje -WhatIf (podgląd bez zmian).

.PARAMETER VHDLocations
    Udział(y) na kontenery profili, np. '\\fs01\Profiles$'. Wymagany.
.PARAMETER SizeInMBs
    Maksymalny rozmiar VHDX (dynamiczny - zajmuje tyle, ile dane). Domyślnie 30000 (ok. 30 GB).
.PARAMETER ProfileIncludeGroups
    Grupy, które dostają kontener (np. 'UCZELNIA\Studenci'). Pusta = Everyone (domyślne FSLogix).
.PARAMETER ProfileExcludeMembers
    Dodatkowe konta/grupy bez kontenera (np. 'UCZELNIA\VDI-Admins').
.PARAMETER ExtraExcludes
    Dodatkowe ścieżki (względem profilu) do wykluczenia w redirections.xml.

.EXAMPLE
    .\Set-FSLogixConfig.ps1 -VHDLocations '\\fs01\Profiles$' -WhatIf
.EXAMPLE
    .\Set-FSLogixConfig.ps1 -VHDLocations '\\fs01\Profiles$' -SizeInMBs 30000 `
        -ProfileIncludeGroups 'UCZELNIA\Studenci','UCZELNIA\Pracownicy' -ProfileExcludeMembers 'UCZELNIA\VDI-Admins'

.NOTES
    Wersja 1.0. Log: C:\ProgramData\VDI-ImageMaint\Logs\FSLogixConfig_<data>.log
    Zmiany rejestru FSLogix działają od następnego logowania - na złotym obrazie: Seal + Push Image.
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

    [switch]$RoamIdentity,              # roaming tożsamości Entra ID (M365/Teams SSO) - FSLogix 2210 HF3+
    [switch]$SkipAntivirus,
    [switch]$NoVhdExtensionExclusion,   # bez globalnego wykluczenia rozszerzeń .vhd/.vhdx
    [int]$ConfigVersion = 1
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$LogDir = Join-Path $env:ProgramData 'VDI-ImageMaint\Logs'
# Log i raport AV powstają także przy -WhatIf (nie zmieniają konfiguracji systemu)
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
    if ($PSCmdlet.ShouldProcess("$Path\$Name", "ustaw na '$show'")) {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Log ("  + {0,-38} {1}" -f $Name, $show) OK
    }
}

# =====================================================================
#  KONFIGURACJA
# =====================================================================
$ProfilesKey = 'HKLM:\SOFTWARE\FSLogix\Profiles'
$FrxApps     = Join-Path $env:ProgramFiles 'FSLogix\Apps'

# Wykluczenia z kontenera profilu (ścieżki względem katalogu profilu użytkownika)
$RedirectionExcludes = @(
    # --- ogólne ---
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
    # --- nowy Teams (MSIX) - wyłącznie foldery zalecane przez Microsoft; NIE wykluczać całego EBWebView ---
    'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs'
    'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\PerfLogs'
    'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\WebStorage'
    # --- klasyczny Teams (jeśli jeszcze występuje) ---
    'AppData\Roaming\Microsoft\Teams\Cache'
    'AppData\Roaming\Microsoft\Teams\blob_storage'
    'AppData\Roaming\Microsoft\Teams\GPUCache'
    'AppData\Roaming\Microsoft\Teams\Service Worker\CacheStorage'
    'AppData\Roaming\Microsoft\Teams\logs'
    'AppData\Roaming\Microsoft\Teams\media-stack'
    'AppData\Roaming\Microsoft\Teams\tmp'
    # --- OneDrive ---
    'AppData\Local\Microsoft\OneDrive\logs'
)

# Foldery komponentów VDI (dodawane, jeśli istnieją na obrazie)
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
# Procesy sesji użytkownika (nie są usługami) - kluczowe dla czasu logowania i wydajności Blast
$VdiUserProcesses = @('FlexEngine.exe', 'FlexDirector*.exe', 'VMBlast*.exe', 'horizon_overlay.exe', 'svservice.exe')
$VdiServicePattern = '(?i)\\Omnissa\\|\\VMware View\\|\\Remote Experience\\|CloudVolumes|AppVolumes|Immidio|\\DEM\\'

# =====================================================================
#  START
# =====================================================================
$log = Join-Path $LogDir "FSLogixConfig_$Stamp.log"
Start-Transcript -Path $log -Force -WhatIf:$false -Confirm:$false | Out-Null
try {
    Write-Log "FSLogix - konfiguracja obrazu VDI | $env:COMPUTERNAME | $([Security.Principal.WindowsIdentity]::GetCurrent().Name)" STEP
    if (Test-Path (Join-Path $FrxApps 'frx.exe')) {
        Write-Log ("FSLogix Apps {0}" -f (Get-Item (Join-Path $FrxApps 'frx.exe')).VersionInfo.ProductVersion) OK
    } else {
        Write-Log "Nie znaleziono $FrxApps\frx.exe - FSLogix nie jest zainstalowany; ustawienia zostaną zapisane, ale nie zadziałają" WARN
    }

    # ---------- 1. Udziały ----------
    Write-Log 'Lokalizacje kontenerów (VHDLocations)' STEP
    foreach ($loc in $VHDLocations) {
        if ($loc -notmatch '^\\\\') { Write-Log "  $loc - to nie jest ścieżka UNC" WARN; continue }
        if (Test-Path $loc) { Write-Log "  $loc - dostępny" OK }
        else { Write-Log "  $loc - niedostępny z tego konta (sprawdź DNS/uprawnienia NTFS i udziału dla użytkowników)" WARN }
    }

    # ---------- 2. Rejestr Profiles ----------
    Write-Log "Rejestr $ProfilesKey" STEP
    Set-Reg $ProfilesKey 'Enabled'                              1
    Set-Reg $ProfilesKey 'VHDLocations'                         $VHDLocations 'MultiString'
    Set-Reg $ProfilesKey 'VolumeType'                           'VHDX' 'String'
    Set-Reg $ProfilesKey 'IsDynamic'                            1
    Set-Reg $ProfilesKey 'SizeInMBs'                            $SizeInMBs
    Set-Reg $ProfilesKey 'ProfileType'                          0          # jeden kontener na użytkownika (odczyt/zapis)
    Set-Reg $ProfilesKey 'DeleteLocalProfileWhenVHDShouldApply' 1          # usuwa lokalny profil kolidujący z kontenerem
    Set-Reg $ProfilesKey 'FlipFlopProfileDirectoryName'         1          # katalogi %username%_%sid% - czytelne na udziale
    Set-Reg $ProfilesKey 'PreventLoginWithFailure'              1          # błąd kontenera = brak logowania (zamiast profilu lokalnego)
    Set-Reg $ProfilesKey 'PreventLoginWithTempProfile'          1
    Set-Reg $ProfilesKey 'LockedRetryCount'                     3          # szybka reakcja na zablokowany VHDX (sesja na innym klonie)
    Set-Reg $ProfilesKey 'LockedRetryInterval'                  15
    Set-Reg $ProfilesKey 'ReAttachRetryCount'                   3
    Set-Reg $ProfilesKey 'ReAttachIntervalSeconds'              15
    Set-Reg $ProfilesKey 'RedirXMLSourceFolder'                 $RedirectionsFolder 'String'
    if ($RoamIdentity) { Set-Reg $ProfilesKey 'RoamIdentity' 1 }

    # ---------- 3. redirections.xml ----------
    Write-Log "redirections.xml -> $RedirectionsFolder" STEP
    $excludes = @($RedirectionExcludes + $ExtraExcludes | Where-Object { $_ } | ForEach-Object { $_.Trim('\') } | Select-Object -Unique)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine("<!-- Wygenerowano: Set-FSLogixConfig.ps1 v$ConfigVersion, $(Get-Date -Format 'yyyy-MM-dd HH:mm') -->")
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
    $norm = { param($t) ($t -split "`r?`n" | Where-Object { $_ -notmatch '^<!-- Wygenerowano' }) -join "`n" }
    if ((& $norm $existing) -eq (& $norm $xmlText)) {
        Write-Log "  bez zmian ($($excludes.Count) wykluczeń)"
    } elseif ($PSCmdlet.ShouldProcess($xmlPath, "zapisz $($excludes.Count) wykluczeń")) {
        New-Item -ItemType Directory -Path $RedirectionsFolder -Force | Out-Null
        if ($existing) { Copy-Item $xmlPath "$xmlPath.bak_$Stamp" -Force; Write-Log "  kopia poprzedniej wersji: redirections.xml.bak_$Stamp" }
        [IO.File]::WriteAllText($xmlPath, $xmlText, (New-Object System.Text.UTF8Encoding($false)))
        [void][xml][IO.File]::ReadAllText($xmlPath)   # walidacja składni
        Write-Log "  zapisano $($excludes.Count) wykluczeń" OK
    }

    # ---------- 4. Grupy lokalne FSLogix ----------
    Write-Log 'Grupy lokalne FSLogix' STEP
    $exGroup = 'FSLogix Profile Exclude List'
    $inGroup = 'FSLogix Profile Include List'
    if (-not (Get-LocalGroup -Name $exGroup -ErrorAction SilentlyContinue)) {
        Write-Log "  brak grup FSLogix (instalator FSLogix tworzy je automatycznie) - pomijam" WARN
    } else {
        $toExclude = @($ProfileExcludeMembers)
        if (-not $NoExcludeCurrentAdmin) { $toExclude += [Security.Principal.WindowsIdentity]::GetCurrent().Name }
        $exMembers = @()
        try { $exMembers = @(Get-LocalGroupMember -Group $exGroup -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { }
        foreach ($m in ($toExclude | Select-Object -Unique)) {
            if ($exMembers -contains $m) { Write-Log "  = $exGroup : $m"; continue }
            if ($PSCmdlet.ShouldProcess($exGroup, "dodaj $m")) {
                try { Add-LocalGroupMember -Group $exGroup -Member $m -ErrorAction Stop; Write-Log "  + $exGroup : $m" OK }
                catch { Write-Log "  $exGroup : $m - $($_.Exception.Message)" WARN }
            }
        }
        if ($ProfileIncludeGroups.Count) {
            $inMembers = @()
            try { $inMembers = @(Get-LocalGroupMember -Group $inGroup -ErrorAction Stop) }
            catch { Write-Log "  $inGroup : nie można odczytać członków ($($_.Exception.Message)) - sprawdź ręcznie, czy Everyone został usunięty" WARN }
            foreach ($g in $ProfileIncludeGroups) {
                if (@($inMembers | Where-Object { $_.Name -eq $g }).Count) { Write-Log "  = $inGroup : $g"; continue }
                if ($PSCmdlet.ShouldProcess($inGroup, "dodaj $g")) {
                    try { Add-LocalGroupMember -Group $inGroup -Member $g -ErrorAction Stop; Write-Log "  + $inGroup : $g" OK }
                    catch { Write-Log "  $inGroup : $g - $($_.Exception.Message)" WARN }
                }
            }
            $everyone = @($inMembers | Where-Object { $_.SID.Value -eq 'S-1-1-0' })
            if ($everyone.Count -and $PSCmdlet.ShouldProcess($inGroup, 'usuń Everyone')) {
                Remove-LocalGroupMember -Group $inGroup -Member (New-Object Security.Principal.SecurityIdentifier 'S-1-1-0')
                Write-Log "  - $inGroup : Everyone (kontenery tylko dla wskazanych grup)" OK
            }
        } else {
            Write-Log "  $inGroup bez zmian (domyślnie Everyone)"
        }
    }

    # ---------- 5. Wykluczenia antywirusa ----------
    $avPaths = New-Object System.Collections.Generic.List[string]
    $avProcs = New-Object System.Collections.Generic.List[string]
    $avExts  = New-Object System.Collections.Generic.List[string]
    # FSLogix wg dokumentacji Microsoft
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

    # Horizon / App Volumes / DEM - tylko to, co jest na obrazie
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

    $avFile = Join-Path $LogDir "AV-wykluczenia_$Stamp.txt"
    @('# Wykluczenia AV dla FSLogix / Horizon / App Volumes / DEM', "# $env:COMPUTERNAME, $(Get-Date -Format 'yyyy-MM-dd HH:mm')", '',
      '[Ścieżki / pliki]') + $avPaths + @('', '[Procesy]') + $avProcs + @('', '[Rozszerzenia]') + $avExts |
        Set-Content -Path $avFile -Encoding UTF8 -WhatIf:$false

    Write-Log 'Wykluczenia antywirusa' STEP
    Write-Log ("  ścieżki: {0}, procesy: {1}, rozszerzenia: {2} (lista: {3})" -f $avPaths.Count, $avProcs.Count, $avExts.Count, $avFile)
    if ($SkipAntivirus) {
        Write-Log '  -SkipAntivirus: nie zmieniam ustawień antywirusa'
    } else {
        $products = @()
        try { $products = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { $_.displayName }) } catch { }
        $mode = ''
        try { $mode = [string](Get-MpComputerStatus -ErrorAction Stop).AMRunningMode } catch { }
        Write-Log ("  antywirus: {0} | Defender: {1}" -f $(if ($products.Count) { $products -join ', ' } else { 'nie wykryto' }), $(if ($mode) { $mode } else { 'niedostępny' }))
        $thirdParty = @($products | Where-Object { $_ -notmatch 'Defender' })
        if ($thirdParty.Count) {
            Write-Log ("  {0}: wprowadź wykluczenia z pliku {1} w konsoli tego produktu (np. Apex One / Vision One - polityka dla puli VDI)" -f ($thirdParty -join ', '), $avFile) WARN
        }
        if ($mode) {
            $pref = Get-MpPreference
            $newPaths = @($avPaths | Where-Object { @($pref.ExclusionPath) -notcontains $_ })
            $newProcs = @($avProcs | Where-Object { @($pref.ExclusionProcess) -notcontains $_ })
            $newExts  = @($avExts  | Where-Object { @($pref.ExclusionExtension) -notcontains $_ })
            if (($newPaths.Count + $newProcs.Count + $newExts.Count) -eq 0) {
                Write-Log '  Defender: wszystkie wykluczenia już ustawione' OK
            } elseif ($PSCmdlet.ShouldProcess('Microsoft Defender', "dodaj wykluczenia: $($newPaths.Count) ścieżek, $($newProcs.Count) procesów, $($newExts.Count) rozszerzeń")) {
                try {
                    if ($newPaths.Count) { Add-MpPreference -ExclusionPath $newPaths -ErrorAction Stop }
                    if ($newProcs.Count) { Add-MpPreference -ExclusionProcess $newProcs -ErrorAction Stop }
                    if ($newExts.Count)  { Add-MpPreference -ExclusionExtension $newExts -ErrorAction Stop }
                    Write-Log ("  Defender: dodano {0} ścieżek, {1} procesów, {2} rozszerzeń" -f $newPaths.Count, $newProcs.Count, $newExts.Count) OK
                } catch {
                    Write-Log "  Defender: $($_.Exception.Message) (Tamper Protection / zarządzanie z Intune? - ustaw wykluczenia w polityce)" WARN
                }
            }
        }
    }

    # ---------- 6. Znacznik wersji (detekcja w manifeście VDI-ImageMaint) ----------
    if ($PSCmdlet.ShouldProcess('HKLM:\SOFTWARE\EMS\VDI-Image', "FSLogixConfigVersion=$ConfigVersion")) {
        if (-not (Test-Path 'HKLM:\SOFTWARE\EMS\VDI-Image')) { New-Item 'HKLM:\SOFTWARE\EMS\VDI-Image' -Force | Out-Null }
        New-ItemProperty -Path 'HKLM:\SOFTWARE\EMS\VDI-Image' -Name 'FSLogixConfigVersion' -Value ([string]$ConfigVersion) -PropertyType String -Force | Out-Null
    }

    Write-Log 'Podsumowanie' STEP
    Write-Log "  VHDX: dynamiczny, max $SizeInMBs MB, $($VHDLocations -join '; ')"
    Write-Log "  redirections.xml: $($excludes.Count) wykluczeń ($xmlPath)"
    Write-Log "  AV: $($avPaths.Count) ścieżek, $($avProcs.Count) procesów, $($avExts.Count) rozszerzeń"
    if ($script:Warnings) { Write-Log "Zakończono z ostrzeżeniami: $($script:Warnings)" WARN } else { Write-Log 'Zakończono poprawnie' OK }
    Write-Log 'Dalej: test logowania na klonie, potem Seal + Push Image. Stare kontenery zachowują dane - nowe wykluczenia działają od kolejnego logowania.'
    $exit = 0
} catch {
    Write-Log $_.Exception.Message ERR
    $exit = 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }   # B3: bez transkrypcji Stop-Transcript rzuca błąd
}
exit $exit
