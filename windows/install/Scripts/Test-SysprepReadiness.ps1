#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Read-only readiness check before OSOT Generalize (Sysprep) on a Windows 11 24H2/25H2 golden image.

.DESCRIPTION
    Checks every known cause of Sysprep /generalize failures on recent Windows 11 builds and prints
    PASS / WARN / FAIL / INFO with the fix for each problem. Nothing is changed on the system.

      C01 Windows version            C11 Store automatic updates
      C02 Audit mode                 C12 Local user profiles
      C03 Sysprep state (registry)   C13 Domain membership
      C04 Remaining rearm count      C14 Horizon agents installed before Generalize
      C05 Pending reboot             C15 Leftover answer files
      C06 Servicing activity         C16 Previous Sysprep errors (Panther logs)
      C07 BitLocker / encryption C:  C17 OSOT version (25H2 needs 2603+, 2606+ recommended)
      C08 Encryption prevention      C18 Free space on C:
      C09 AppX per user, not         C19 Sysprep already running
          provisioned (0x80073cf2)   C20 In-place upgrade history
      C10 AppX updated per user

    Exit code: 0 = all PASS/INFO, 1 = warnings, 2 = at least one FAIL (do not run Generalize).

.PARAMETER Language
    auto (UI culture: pl -> Polish, everything else -> English), en, pl.
.PARAMETER InstallDir
    Folder searched for the OSOT executable (default C:\install).
.PARAMETER OutFile
    Optional JSON report path.
.PARAMETER SkipAppxScan
    Skip C09/C10 (Get-AppxPackage -AllUsers can take a minute).

.EXAMPLE
    .\Test-SysprepReadiness.ps1
.EXAMPLE
    .\Test-SysprepReadiness.ps1 -Language pl -OutFile C:\ProgramData\VDI-ImageMaint\Logs\sysprep-readiness.json

.NOTES
    Version 0.1. Run in Windows PowerShell 5.1 (the Appx module is not reliable in pwsh 7).
    Sources: Omnissa TechZone "Manually creating optimized Windows images for Horizon VMs",
    Omnissa KB 77253, Microsoft Q&A on 24H2 Sysprep AppX failures.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'InstallDir',
    Justification = 'Used inside the C17 Invoke-Check scriptblock')]
[CmdletBinding()]
param(
    [ValidateSet('auto', 'en', 'pl')]
    [string]$Language = 'auto',
    [string]$InstallDir = 'C:\install',
    [string]$OutFile,
    [switch]$SkipAppxScan
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# =====================================================================
#  STRINGS (en = primary, pl = secondary; same keys in both)
# =====================================================================
$Strings = @{
    en = @{
        'hdr'          = 'Sysprep readiness | {0} | {1} | {2}'
        'err.check'    = 'check failed: {0}'
        'sum'          = 'Result: {0} FAIL, {1} WARN, {2} PASS, {3} INFO'
        'sum.fail'     = 'Do NOT run Generalize - fix the FAIL items first (snapshot the VM before Generalize).'
        'sum.warn'     = 'Generalize possible, but review the warnings.'
        'sum.ok'       = 'Ready for Generalize. Take the "pre-generalize" snapshot first.'
        'fixes'        = 'How to fix'
        'report'       = 'Report: {0}'
        'pwsh'         = 'Running in PowerShell 7 - the Appx cmdlets may fail; use Windows PowerShell 5.1.'
        'C01' = 'Windows version';                     'C01.d' = '{0} {1} build {2}.{3} ({4})'
        'C01.unsup'    = 'build {0} is not 24H2 (26100) or 25H2 (26200) - checks tuned for these'
        'C02' = 'Audit mode';                          'C02.yes' = 'audit mode (ImageState={0})'
        'C02.no'       = 'not in audit mode (ImageState={0}). OSOT Generalize requires audit mode'
        'C02.fix'      = 'Build from a clean ISO and press Ctrl+Shift+F3 at the first OOBE screen. On an existing image, generalize a copy of the VM, not the production golden image.'
        'C03' = 'Sysprep state (registry)';            'C03.d' = 'GeneralizationState={0}, CleanupState={1}'
        'C03.fix'      = 'Expected GeneralizationState=7 and CleanupState=2. Other values usually mean an interrupted Sysprep - read the Panther logs (C16) before changing them.'
        'C04' = 'Remaining rearm count';               'C04.d' = '{0}'
        'C04.fix'      = 'No rearm left: use an answer file with Microsoft-Windows-Security-SPP/SkipRearm=1, or rebuild from ISO.'
        'C05' = 'Pending reboot';                      'C05.none' = 'none'
        'C05.fix'      = 'Reboot (repeat until clean). Sysprep fails with 0x36b7 "updates that require a reboot".'
        'C06' = 'Servicing activity';                  'C06.none' = 'idle'
        'C06.d'        = 'running: {0}'
        'C06.fix'      = 'Wait until Windows servicing finishes (TiWorker / TrustedInstaller / MoUsoCoreWorker), then reboot.'
        'C07' = 'BitLocker / device encryption on C:'; 'C07.na' = 'BitLocker not available on this system'
        'C07.d'        = '{0} ({1}%), protection {2}'
        'C07.fix'      = 'Run "manage-bde -off C:" and wait until C: is FullyDecrypted (manage-bde -status C:). Sysprep fails when leaving audit mode on an encrypted drive.'
        'C08' = 'Device encryption prevention';        'C08.d' = 'PreventDeviceEncryption={0}, BDESVC start={1}'
        'C08.fix'      = 'Set HKLM\SYSTEM\CurrentControlSet\Control\BitLocker PreventDeviceEncryption=1 (DWORD) and disable BDESVC (unless the customer uses BitLocker on clones). OSOT 2606+ does this in Optimize.'
        'C09' = 'AppX installed per user but not provisioned'
        'C09.none'     = 'none'
        'C09.d'        = '{0} package(s): {1}'
        'C09.fix'      = 'For each package: Remove-AppxPackage -Package <PackageFullName> -AllUsers. New Teams (MSTeams): provision it with "teamsbootstrapper.exe -p" instead of removing. Copilot/BingSearch: remove. This is the 0x80073cf2 failure.'
        'C09.skip'     = 'skipped (-SkipAppxScan)'
        'C10' = 'AppX updated per user (newer than provisioned)'
        'C10.none'     = 'none'
        'C10.d'        = '{0} package(s): {1}'
        'C10.fix'      = 'The Store updated these for a user only. Remove the per-user version (Remove-AppxPackage -AllUsers) or update the provisioned package (Add-AppxProvisionedPackage), and set Store AutoDownload=2 (C11).'
        'C11' = 'Store automatic updates';             'C11.d' = 'WindowsStore AutoDownload={0}'
        'C11.fix'      = 'Set HKLM\SOFTWARE\Policies\Microsoft\WindowsStore AutoDownload=2 before working in audit mode, and do not open the Store.'
        'C12' = 'Local user profiles';                 'C12.ok' = 'only built-in accounts'
        'C12.d'        = 'extra profiles: {0}'
        'C12.fix'      = 'In audit mode only the built-in Administrator should have a profile. Extra profiles carry per-user AppX (C09). Remove them in System Properties > User Profiles.'
        'C13' = 'Domain membership';                   'C13.no' = 'workgroup'
        'C13.d'        = 'joined to {0} - Generalize removes the domain membership'
        'C14' = 'Horizon agents installed before Generalize'
        'C14.none'     = 'none'
        'C14.d'        = 'installed: {0}'
        'C14.fix'      = 'Omnissa order is Optimize > Generalize > agents > Finalize. Install Horizon Agent, DEM and App Volumes Agent after Generalize.'
        'C15' = 'Leftover answer files';               'C15.none' = 'none'
        'C15.d'        = 'found: {0}'
        'C15.fix'      = 'Remove stale unattend.xml files - Windows Setup picks them up implicitly in later passes.'
        'C16' = 'Previous Sysprep errors';             'C16.none' = 'no errors in setuperr.log'
        'C16.d'        = 'last errors: {0}'
        'C16.fix'      = 'Read C:\Windows\System32\Sysprep\Panther\setupact.log around these timestamps. Errors from an old attempt are only informational.'
        'C17' = 'OSOT version';                        'C17.none' = 'OSOT not found in {0}'
        'C17.d'        = '{0} (release {1})'
        'C17.old'      = 'release {0} is too old for 25H2 (needs 2603+)'
        'C17.fix'      = 'Download the current OSOT (2606+ recommended: it turns off device encryption and BitLocker in Optimize) - see docs/downloads.md.'
        'C18' = 'Free space on C:';                    'C18.d' = '{0:N1} GB free'
        'C18.fix'      = 'Free at least 10 GB (Finalize 1/3, remove Office\Data downloads).'
        'C19' = 'Sysprep already running';             'C19.no' = 'no'
        'C19.d'        = 'sysprep.exe is running (PID {0})'
        'C19.fix'      = 'Wait for it to finish or close the Sysprep dialog (audit mode opens it on every logon).'
        'C20' = 'In-place upgrade history';            'C20.no' = 'clean install'
        'C20.d'        = '{0} upgrade record(s): {1}'
        'C20.fix'      = 'The image was upgraded in place. Supported, but a common source of Sysprep/OOBE issues - prefer a clean build for each feature release.'
    }
    pl = @{
        'hdr'          = 'Gotowość do Sysprep | {0} | {1} | {2}'
        'err.check'    = 'sprawdzenie nieudane: {0}'
        'sum'          = 'Wynik: {0} FAIL, {1} WARN, {2} PASS, {3} INFO'
        'sum.fail'     = 'NIE uruchamiaj Generalize - najpierw usuń pozycje FAIL (przed Generalize zrób snapshot VM).'
        'sum.warn'     = 'Generalize możliwe, ale przejrzyj ostrzeżenia.'
        'sum.ok'       = 'Gotowe do Generalize. Najpierw zrób snapshot "pre-generalize".'
        'fixes'        = 'Jak naprawić'
        'report'       = 'Raport: {0}'
        'pwsh'         = 'Uruchomiono w PowerShell 7 - polecenia Appx mogą nie działać; użyj Windows PowerShell 5.1.'
        'C01' = 'Wersja Windows';                      'C01.d' = '{0} {1} kompilacja {2}.{3} ({4})'
        'C01.unsup'    = 'kompilacja {0} to nie 24H2 (26100) ani 25H2 (26200) - kontrole są dostrojone do tych wersji'
        'C02' = 'Tryb audytu';                         'C02.yes' = 'tryb audytu (ImageState={0})'
        'C02.no'       = 'nie jest w trybie audytu (ImageState={0}). OSOT Generalize wymaga trybu audytu'
        'C02.fix'      = 'Zbuduj obraz z czystego ISO i na pierwszym ekranie OOBE naciśnij Ctrl+Shift+F3. Na istniejącym obrazie uogólniaj kopię VM, nie produkcyjny obraz wzorcowy.'
        'C03' = 'Stan Sysprep (rejestr)';              'C03.d' = 'GeneralizationState={0}, CleanupState={1}'
        'C03.fix'      = 'Oczekiwane GeneralizationState=7 i CleanupState=2. Inne wartości zwykle oznaczają przerwany Sysprep - zanim je zmienisz, przeczytaj logi Panther (C16).'
        'C04' = 'Pozostałe rearm';                     'C04.d' = '{0}'
        'C04.fix'      = 'Brak rearm: użyj pliku odpowiedzi z Microsoft-Windows-Security-SPP/SkipRearm=1 albo zbuduj obraz od nowa z ISO.'
        'C05' = 'Oczekujący restart';                  'C05.none' = 'brak'
        'C05.fix'      = 'Zrestartuj (powtarzaj, aż będzie czysto). Sysprep kończy się błędem 0x36b7 "updates that require a reboot".'
        'C06' = 'Aktywność serwisowania';              'C06.none' = 'bezczynny'
        'C06.d'        = 'działa: {0}'
        'C06.fix'      = 'Poczekaj, aż serwisowanie Windows się zakończy (TiWorker / TrustedInstaller / MoUsoCoreWorker), potem zrestartuj.'
        'C07' = 'BitLocker / szyfrowanie urządzenia na C:'; 'C07.na' = 'BitLocker niedostępny w tym systemie'
        'C07.d'        = '{0} ({1}%), ochrona {2}'
        'C07.fix'      = 'Uruchom "manage-bde -off C:" i poczekaj, aż C: będzie FullyDecrypted (manage-bde -status C:). Na zaszyfrowanym dysku Sysprep kończy się błędem przy wyjściu z trybu audytu.'
        'C08' = 'Blokada szyfrowania urządzenia';      'C08.d' = 'PreventDeviceEncryption={0}, start BDESVC={1}'
        'C08.fix'      = 'Ustaw HKLM\SYSTEM\CurrentControlSet\Control\BitLocker PreventDeviceEncryption=1 (DWORD) i wyłącz BDESVC (chyba że klient używa BitLockera na klonach). OSOT 2606+ robi to w Optimize.'
        'C09' = 'AppX zainstalowane dla konta, ale niezaprowizjonowane'
        'C09.none'     = 'brak'
        'C09.d'        = '{0} pakiet(ów): {1}'
        'C09.fix'      = 'Dla każdego pakietu: Remove-AppxPackage -Package <PackageFullName> -AllUsers. Nowy Teams (MSTeams): nie usuwaj, tylko zaprowizjonuj przez "teamsbootstrapper.exe -p". Copilot/BingSearch: usuń. To błąd 0x80073cf2.'
        'C09.skip'     = 'pominięto (-SkipAppxScan)'
        'C10' = 'AppX zaktualizowane dla konta (nowsze niż zaprowizjonowane)'
        'C10.none'     = 'brak'
        'C10.d'        = '{0} pakiet(ów): {1}'
        'C10.fix'      = 'Store zaktualizował je tylko dla jednego konta. Usuń wersję użytkownika (Remove-AppxPackage -AllUsers) albo zaktualizuj pakiet zaprowizjonowany (Add-AppxProvisionedPackage) i ustaw AutoDownload=2 dla Store (C11).'
        'C11' = 'Automatyczne aktualizacje Store';     'C11.d' = 'WindowsStore AutoDownload={0}'
        'C11.fix'      = 'Ustaw HKLM\SOFTWARE\Policies\Microsoft\WindowsStore AutoDownload=2 przed pracą w trybie audytu i nie otwieraj Store.'
        'C12' = 'Lokalne profile użytkowników';        'C12.ok' = 'tylko konta wbudowane'
        'C12.d'        = 'dodatkowe profile: {0}'
        'C12.fix'      = 'W trybie audytu profil powinien mieć tylko wbudowany Administrator. Dodatkowe profile niosą AppX zainstalowane dla konta (C09). Usuń je w Właściwości systemu > Profile użytkowników.'
        'C13' = 'Członkostwo w domenie';               'C13.no' = 'grupa robocza'
        'C13.d'        = 'w domenie {0} - Generalize usuwa członkostwo w domenie'
        'C14' = 'Agenty Horizon zainstalowane przed Generalize'
        'C14.none'     = 'brak'
        'C14.d'        = 'zainstalowane: {0}'
        'C14.fix'      = 'Kolejność według Omnissa: Optimize > Generalize > agenty > Finalize. Horizon Agent, DEM i App Volumes Agent instaluj po Generalize.'
        'C15' = 'Pozostałe pliki odpowiedzi';          'C15.none' = 'brak'
        'C15.d'        = 'znaleziono: {0}'
        'C15.fix'      = 'Usuń stare pliki unattend.xml - Windows Setup użyje ich po cichu w kolejnych fazach.'
        'C16' = 'Poprzednie błędy Sysprep';            'C16.none' = 'brak błędów w setuperr.log'
        'C16.d'        = 'ostatnie błędy: {0}'
        'C16.fix'      = 'Przeczytaj C:\Windows\System32\Sysprep\Panther\setupact.log w okolicy tych godzin. Błędy ze starej próby są tylko informacją.'
        'C17' = 'Wersja OSOT';                         'C17.none' = 'nie znaleziono OSOT w {0}'
        'C17.d'        = '{0} (wydanie {1})'
        'C17.old'      = 'wydanie {0} jest za stare dla 25H2 (wymagane 2603+)'
        'C17.fix'      = 'Pobierz aktualny OSOT (zalecane 2606+: w Optimize wyłącza szyfrowanie urządzenia i BitLocker) - patrz docs/pl/downloads.md.'
        'C18' = 'Wolne miejsce na C:';                 'C18.d' = '{0:N1} GB wolne'
        'C18.fix'      = 'Zwolnij co najmniej 10 GB (Finalize 1/3, usuń pobrane pliki z Office\Data).'
        'C19' = 'Sysprep już działa';                  'C19.no' = 'nie'
        'C19.d'        = 'sysprep.exe działa (PID {0})'
        'C19.fix'      = 'Poczekaj na zakończenie albo zamknij okno Sysprep (tryb audytu otwiera je przy każdym logowaniu).'
        'C20' = 'Historia aktualizacji in-place';      'C20.no' = 'czysta instalacja'
        'C20.d'        = '{0} wpis(ów) aktualizacji: {1}'
        'C20.fix'      = 'Obraz był aktualizowany in-place. To wspierane, ale często powoduje problemy z Sysprep i OOBE - każde wydanie funkcji najlepiej budować od nowa.'
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

# =====================================================================
#  HELPERS
# =====================================================================
function Get-RegValue {
    # No exceptions on a missing key/value (PS 5.1 writes caught exceptions to the transcript)
    param([string]$Path, [string]$Name)
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    return $key.GetValue($Name, $null)
}

function Get-P {
    # Safe property read under StrictMode (property may not exist on older builds)
    param($Obj, [string]$Name, $Default = $null)
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name) { return $Obj.$Name }
    return $Default
}

function Show-Value { param($Value) if ($null -eq $Value -or "$Value" -eq '') { return '-' } return [string]$Value }

$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Id,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status,
        [string]$Detail,
        [string]$Fix = ''
    )
    $script:Results.Add([pscustomobject]@{ Id = $Id; Status = $Status; Check = (T $Id); Detail = $Detail; Fix = $Fix })
}

function Invoke-Check {
    param([string]$Id, [scriptblock]$Body)
    try { & $Body }
    catch { Add-Result -Id $Id -Status 'WARN' -Detail (T 'err.check' @($_.Exception.Message)) }
}

# =====================================================================
#  CHECKS
# =====================================================================
$NtKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$Build = [int](Get-RegValue $NtKey 'CurrentBuildNumber')

Invoke-Check 'C01' {
    $d = T 'C01.d' @((Get-RegValue $NtKey 'ProductName'), (Get-RegValue $NtKey 'EditionID'), $Build,
        (Get-RegValue $NtKey 'UBR'), (Get-RegValue $NtKey 'DisplayVersion'))
    # ProductName still says "Windows 10" on Windows 11 - the build number is authoritative
    if ($Build -in 26100, 26200) { Add-Result 'C01' 'INFO' $d }
    else { Add-Result 'C01' 'WARN' ("$d; " + (T 'C01.unsup' @($Build))) }
}

Invoke-Check 'C02' {
    $state = [string](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' 'ImageState')
    $auditKey = Test-Path 'HKLM:\SYSTEM\Setup\Status\AuditBoot'
    if ($auditKey -or $state -match 'RESEAL_TO_AUDIT|UNDEPLOYABLE') { Add-Result 'C02' 'PASS' (T 'C02.yes' @(Show-Value $state)) }
    else { Add-Result 'C02' 'WARN' (T 'C02.no' @(Show-Value $state)) (T 'C02.fix') }
}

Invoke-Check 'C03' {
    $k = 'HKLM:\SYSTEM\Setup\Status\SysprepStatus'
    $g = Get-RegValue $k 'GeneralizationState'
    $c = Get-RegValue $k 'CleanupState'
    $d = T 'C03.d' @((Show-Value $g), (Show-Value $c))
    if (($null -ne $g -and [int]$g -ne 7) -or ($null -ne $c -and [int]$c -ne 2)) { Add-Result 'C03' 'WARN' $d (T 'C03.fix') }
    else { Add-Result 'C03' 'PASS' $d }
}

Invoke-Check 'C04' {
    $sls = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
    $n = [int](Get-P $sls 'RemainingWindowsReArmCount' -1)
    if ($n -eq 0) { Add-Result 'C04' 'FAIL' (T 'C04.d' @($n)) (T 'C04.fix') }
    elseif ($n -lt 0) { Add-Result 'C04' 'INFO' (T 'C04.d' @('?')) }
    else { Add-Result 'C04' 'PASS' (T 'C04.d' @($n)) }
}

Invoke-Check 'C05' {
    $hard = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $hard += 'CBS RebootPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending') { $hard += 'CBS PackagesPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $hard += 'WindowsUpdate RebootRequired' }
    $soft = @()
    if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') { $soft += 'PendingFileRenameOperations' }
    if ($hard.Count) { Add-Result 'C05' 'FAIL' (($hard + $soft) -join ', ') (T 'C05.fix') }
    elseif ($soft.Count) { Add-Result 'C05' 'WARN' ($soft -join ', ') (T 'C05.fix') }
    else { Add-Result 'C05' 'PASS' (T 'C05.none') }
}

Invoke-Check 'C06' {
    $busy = @(Get-Process -Name TiWorker, MoUsoCoreWorker, TrustedInstaller -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Select-Object -Unique)
    if ($busy.Count) { Add-Result 'C06' 'WARN' (T 'C06.d' @($busy -join ', ')) (T 'C06.fix') }
    else { Add-Result 'C06' 'PASS' (T 'C06.none') }
}

Invoke-Check 'C07' {
    $vol = $null
    try {
        $vol = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$($env:SystemDrive)'" -ErrorAction Stop
    } catch { $vol = $null }
    if (-not $vol) { Add-Result 'C07' 'PASS' (T 'C07.na'); return }
    $cs = Invoke-CimMethod -InputObject $vol -MethodName GetConversionStatus
    $names = @{ 0 = 'FullyDecrypted'; 1 = 'FullyEncrypted'; 2 = 'EncryptionInProgress'; 3 = 'DecryptionInProgress'; 4 = 'EncryptionPaused'; 5 = 'DecryptionPaused' }
    $status = [int]$cs.ConversionStatus
    $prot = $(if ([int](Get-P $vol 'ProtectionStatus' 0) -eq 1) { 'On' } else { 'Off' })
    $d = T 'C07.d' @($names[$status], [int]$cs.EncryptionPercentage, $prot)
    # Device encryption can leave C: encrypted with protection Off (clear key) - still a Sysprep blocker
    if ($status -eq 0) { Add-Result 'C07' 'PASS' $d } else { Add-Result 'C07' 'FAIL' $d (T 'C07.fix') }
}

Invoke-Check 'C08' {
    $pde = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption'
    $bde = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\BDESVC' 'Start'
    $d = T 'C08.d' @((Show-Value $pde), (Show-Value $bde))
    if ($pde -eq 1 -and ($null -eq $bde -or $bde -eq 4)) { Add-Result 'C08' 'PASS' $d }
    else { Add-Result 'C08' 'WARN' $d (T 'C08.fix') }
}

if ($SkipAppxScan) {
    Add-Result 'C09' 'INFO' (T 'C09.skip')
    Add-Result 'C10' 'INFO' (T 'C09.skip')
} else {
    if ($PSVersionTable.PSEdition -eq 'Core') { Write-Warning (T 'pwsh') }
    Invoke-Check 'C09' {
        $prov = @{}
        foreach ($p in @(Get-AppxProvisionedPackage -Online)) { $prov[[string]$p.DisplayName] = [string]$p.Version }
        $notProv = @(); $newer = @()
        foreach ($a in @(Get-AppxPackage -AllUsers)) {
            if ((Get-P $a 'IsFramework' $false) -or (Get-P $a 'IsResourcePackage' $false) -or (Get-P $a 'NonRemovable' $false)) { continue }
            # Inbox system apps are never provisioned and do not block Sysprep
            if ([string](Get-P $a 'SignatureKind' '') -eq 'System') { continue }
            $users = @(@(Get-P $a 'PackageUserInformation' @()) | Where-Object { [string]$_.InstallState -eq 'Installed' })
            if ($users.Count -eq 0) { continue }
            $who = (@($users | ForEach-Object { [string](Get-P (Get-P $_ 'UserSecurityId') 'Username' '') }) | Where-Object { $_ } | Select-Object -Unique) -join '/'
            $label = '{0} {1} [{2}]' -f $a.Name, $a.Version, $who
            if (-not $prov.ContainsKey([string]$a.Name)) { $notProv += $label; continue }
            $pv = $null; $av = $null
            if ([version]::TryParse($prov[[string]$a.Name], [ref]$pv) -and [version]::TryParse([string]$a.Version, [ref]$av) -and $av -gt $pv) {
                $newer += ('{0} {1} > {2} [{3}]' -f $a.Name, $a.Version, $pv, $who)
            }
        }
        $notProv = @($notProv | Sort-Object -Unique)
        $newer   = @($newer | Sort-Object -Unique)
        if ($notProv.Count) { Add-Result 'C09' 'FAIL' (T 'C09.d' @($notProv.Count, ($notProv -join '; '))) (T 'C09.fix') }
        else { Add-Result 'C09' 'PASS' (T 'C09.none') }
        if ($newer.Count) { Add-Result 'C10' 'WARN' (T 'C10.d' @($newer.Count, ($newer -join '; '))) (T 'C10.fix') }
        else { Add-Result 'C10' 'PASS' (T 'C10.none') }
    }
    # C10 comes from the same scan - report it too when the scan failed
    if (-not @($script:Results | Where-Object { $_.Id -eq 'C10' }).Count) { Add-Result 'C10' 'WARN' (T 'err.check' @('C09')) }
}

Invoke-Check 'C11' {
    $v = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload'
    if ($v -eq 2) { Add-Result 'C11' 'PASS' (T 'C11.d' @($v)) }
    else { Add-Result 'C11' 'WARN' (T 'C11.d' @(Show-Value $v)) (T 'C11.fix') }
}

Invoke-Check 'C12' {
    # Built-in Administrator has RID 500; Special = service/system profiles
    $extra = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
        Where-Object { -not $_.Special -and $_.SID -notmatch '-500$' } |
        ForEach-Object { Split-Path $_.LocalPath -Leaf })
    if ($extra.Count) { Add-Result 'C12' 'WARN' (T 'C12.d' @($extra -join ', ')) (T 'C12.fix') }
    else { Add-Result 'C12' 'PASS' (T 'C12.ok') }
}

Invoke-Check 'C13' {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($cs.PartOfDomain) { Add-Result 'C13' 'INFO' (T 'C13.d' @($cs.Domain)) }
    else { Add-Result 'C13' 'INFO' (T 'C13.no') }
}

Invoke-Check 'C14' {
    $apps = @(foreach ($h in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        Get-ItemProperty -Path $h -ErrorAction SilentlyContinue | ForEach-Object { [string](Get-P $_ 'DisplayName' '') }
    })
    $agents = @($apps | Where-Object { $_ -match 'Horizon Agent$|App Volumes Agent|Dynamic Environment Manager' } | Sort-Object -Unique)
    if ($agents.Count) { Add-Result 'C14' 'WARN' (T 'C14.d' @($agents -join ', ')) (T 'C14.fix') }
    else { Add-Result 'C14' 'PASS' (T 'C14.none') }
}

Invoke-Check 'C15' {
    $cands = @(
        (Join-Path $env:SystemRoot 'Panther\unattend.xml'),
        (Join-Path $env:SystemRoot 'Panther\Unattend\unattend.xml'),
        (Join-Path $env:SystemRoot 'System32\Sysprep\unattend.xml'),
        (Join-Path $env:SystemDrive 'unattend.xml'),
        (Join-Path $env:SystemDrive 'autounattend.xml')
    )
    $found = @($cands | Where-Object { Test-Path -LiteralPath $_ })
    $regFile = Get-RegValue 'HKLM:\SYSTEM\Setup' 'UnattendFile'
    if ($regFile) { $found += "HKLM\SYSTEM\Setup\UnattendFile=$regFile" }
    if ($found.Count) { Add-Result 'C15' 'WARN' (T 'C15.d' @($found -join ', ')) (T 'C15.fix') }
    else { Add-Result 'C15' 'PASS' (T 'C15.none') }
}

Invoke-Check 'C16' {
    $log = Join-Path $env:SystemRoot 'System32\Sysprep\Panther\setuperr.log'
    $errs = @()
    if (Test-Path -LiteralPath $log) {
        $errs = @(Get-Content -LiteralPath $log -ErrorAction Stop | Where-Object { $_ -match ',\s*Error\s' } | Select-Object -Last 3 |
            ForEach-Object { ($_ -replace '\s+', ' ').Trim() })
    }
    if ($errs.Count) { Add-Result 'C16' 'INFO' (T 'C16.d' @($errs -join ' || ')) (T 'C16.fix') }
    else { Add-Result 'C16' 'PASS' (T 'C16.none') }
}

Invoke-Check 'C17' {
    $exe = $null
    if (Test-Path -LiteralPath $InstallDir) {
        $exe = Get-ChildItem -Path $InstallDir -Recurse -File -Include '*OS*Optimization*Tool*.exe', '*OSOT*.exe' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if (-not $exe) { Add-Result 'C17' 'WARN' (T 'C17.none' @($InstallDir)) (T 'C17.fix'); return }
    # Release = YYMM (e.g. 2603) taken from the file name or version resource
    $text = '{0} {1} {2}' -f $exe.Name, $exe.VersionInfo.ProductVersion, $exe.VersionInfo.FileVersion
    $rel = @([regex]::Matches($text, '(?<!\d)(2[2-9](0[1-9]|1[0-2]))(?!\d)') | ForEach-Object { [int]$_.Value }) |
        Sort-Object -Descending | Select-Object -First 1
    $d = T 'C17.d' @($exe.Name, (Show-Value $rel))
    if (-not $rel) { Add-Result 'C17' 'INFO' $d (T 'C17.fix') }
    elseif ($Build -ge 26200 -and $rel -lt 2603) { Add-Result 'C17' 'FAIL' ("$d; " + (T 'C17.old' @($rel))) (T 'C17.fix') }
    elseif ($rel -lt 2606) { Add-Result 'C17' 'WARN' $d (T 'C17.fix') }
    else { Add-Result 'C17' 'PASS' $d }
}

Invoke-Check 'C18' {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
    $gb = [double]$disk.FreeSpace / 1GB
    if ($gb -lt 10) { Add-Result 'C18' 'WARN' (T 'C18.d' @($gb)) (T 'C18.fix') }
    else { Add-Result 'C18' 'PASS' (T 'C18.d' @($gb)) }
}

Invoke-Check 'C19' {
    $sp = @(Get-Process -Name sysprep -ErrorAction SilentlyContinue)
    if ($sp.Count) { Add-Result 'C19' 'WARN' (T 'C19.d' @(($sp | ForEach-Object { $_.Id }) -join ', ')) (T 'C19.fix') }
    else { Add-Result 'C19' 'PASS' (T 'C19.no') }
}

Invoke-Check 'C20' {
    # Feature updates leave "Source OS (Updated on <date>)" keys under HKLM\SYSTEM\Setup
    $up = @(Get-ChildItem -Path 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like 'Source OS*' } | ForEach-Object { $_.PSChildName -replace '^Source OS\s*', '' })
    if ($up.Count) { Add-Result 'C20' 'WARN' (T 'C20.d' @($up.Count, ($up -join ', '))) (T 'C20.fix') }
    else { Add-Result 'C20' 'PASS' (T 'C20.no') }
}

# =====================================================================
#  REPORT
# =====================================================================
$colors = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }
Write-Host ''
Write-Host (T 'hdr' @($env:COMPUTERNAME, [Security.Principal.WindowsIdentity]::GetCurrent().Name, (Get-Date -Format 'yyyy-MM-dd HH:mm'))) -ForegroundColor Cyan
foreach ($r in ($script:Results | Sort-Object Id)) {
    Write-Host ('[{0}] {1} {2,-48} {3}' -f $r.Status.PadRight(4), $r.Id, $r.Check, $r.Detail) -ForegroundColor $colors[$r.Status]
}
$todo = @($script:Results | Where-Object { $_.Fix -and $_.Status -in 'FAIL', 'WARN' } | Sort-Object @{ Expression = { $_.Status -ne 'FAIL' } }, Id)
if ($todo.Count) {
    Write-Host ''
    Write-Host (T 'fixes') -ForegroundColor Cyan
    foreach ($r in $todo) { Write-Host ('  {0} {1}: {2}' -f $r.Id, $r.Status, $r.Fix) -ForegroundColor $colors[$r.Status] }
}

$nFail = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$nWarn = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
$nPass = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$nInfo = @($script:Results | Where-Object { $_.Status -eq 'INFO' }).Count
Write-Host ''
Write-Host (T 'sum' @($nFail, $nWarn, $nPass, $nInfo)) -ForegroundColor Cyan
if ($nFail)     { Write-Host (T 'sum.fail') -ForegroundColor Red }
elseif ($nWarn) { Write-Host (T 'sum.warn') -ForegroundColor Yellow }
else            { Write-Host (T 'sum.ok') -ForegroundColor Green }

if ($OutFile) {
    [pscustomobject]@{
        Computer = $env:COMPUTERNAME; Created = (Get-Date).ToString('s'); Build = $Build; Language = $Lang
        # .ToArray(): @(List[object]) inside a hashtable literal throws "argument types do not match" in PS 5.1
        Fail = $nFail; Warn = $nWarn; Results = $script:Results.ToArray()
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $OutFile -Encoding UTF8
    Write-Host (T 'report' @($OutFile))
}

if ($nFail) { exit 2 } elseif ($nWarn) { exit 1 } else { exit 0 }
