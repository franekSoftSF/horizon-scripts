#Requires -Version 5.1
<#
.SYNOPSIS
    Step-by-step menu for VDI-ImageMaint (started by START.cmd). English / Polish.

.DESCRIPTION
    Shows the steps in the right order (first setup, image build, monthly update, tools), explains each
    step, asks only yes/no questions and runs VDI-ImageMaint.ps1 with the right parameters in a separate
    Windows PowerShell process. Nothing here changes the system by itself.

.PARAMETER Language
    auto (UI culture: pl -> Polish, everything else -> English), en, pl.
#>
[CmdletBinding()]
param(
    [ValidateSet('auto', 'en', 'pl')]
    [string]$Language = 'auto'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Root   = Split-Path $PSScriptRoot -Parent            # C:\install
$Tool   = Join-Path $Root 'VDI-ImageMaint.ps1'
$Check  = Join-Path $PSScriptRoot 'Test-SysprepReadiness.ps1'
$Media  = Join-Path $PSScriptRoot 'New-BuildMedia.ps1'
$VCenter = Join-Path $PSScriptRoot 'Invoke-GoldenVm.ps1'
$Push   = Join-Path $PSScriptRoot 'Invoke-HorizonPushImage.ps1'
$LogDir = Join-Path $env:ProgramData 'VDI-ImageMaint\Logs'

# =====================================================================
#  STRINGS (en = primary, pl = secondary; same keys in both)
# =====================================================================
$Strings = @{
    en = @{
        'title'      = 'VDI-ImageMaint - Omnissa Horizon golden image'
        'sec.first'  = 'FIRST SETUP'
        'sec.build'  = 'BUILD A NEW IMAGE (once per Windows release, VM in audit mode)'
        'sec.month'  = 'MONTHLY UPDATE (existing image)'
        'sec.tools'  = 'TOOLS'
        'm1' = 'Configuration wizard (profile, Office, FSLogix, OSOT, apps)'
        'm2' = 'Download the free packages (Office, Teams, FSLogix, OneDrive, VMware Tools...)'
        'm3' = 'Plan - what will be installed (changes nothing)'
        'm4' = 'Updates and packages (automatic reboots)'
        'm5' = 'OSOT optimization (then reboot)'
        'm6' = 'Sysprep readiness check'
        'm7' = 'Generalize (Sysprep) and finish the build automatically'
        'm8' = 'Everything automatically: download, update, reboots, seal, shut down'
        'm9' = 'Seal only (block updates, finalize) - after manual changes'
        'mS' = 'Status'; 'mU' = 'Unlock'; 'mI' = 'Inventory'; 'mV' = 'Check manifest'; 'mL' = 'Open logs'; 'mQ' = 'Quit'
        'mB' = 'Build media for a new VM (ISO: unattended install to audit mode + C:\install)'
        'mO' = 'Build media with OSDCloud (WinPE downloads Windows; needs ADK + OSD module)'
        'mC' = 'vCenter: create the golden image VM and start the installation (vcenter.json)'
        'mR' = 'vCenter: release for the pool (empty CDs, no vTPM, snapshot) - VM powered off'
        'q.osd' = 'Use the OSDCloud media (VDI-OSDCloud.iso) instead of VDI-Build.iso?'
        'mP' = 'Horizon: Push Image of the newest Gold snapshot to the pools (vcenter.json Horizon)'
        'q.push' = 'Push the image now? Users follow the logoff policy from vcenter.json'
        'choice'     = 'Select a step and press Enter'
        'i1' = 'Answer the questions. Enter accepts the default in brackets. Every file is backed up first.'
        'i2' = 'Downloads the packages that need no login into the right folders, checks their signatures and extracts the archives. Packages that need a login (OSOT, Horizon agents) are listed at the end.'
        'i4' = 'Installs packages, Office, Teams, winget apps and Windows updates. The VM reboots by itself and continues after logon (a new window opens).'
        'i5' = 'OSOT optimizes the image with OSOT\Optimize.json. Reboot before step 6.'
        'i6' = 'Checks every known cause of Sysprep failures. Nothing is changed.'
        'i7' = 'Runs Sysprep. After OOBE the VM logs on automatically, installs the Horizon agents, reboots as needed, seals and finalizes. You will be asked for the administrator password.'
        'i8' = 'Downloads fresh packages, unlocks, updates with automatic reboots, then seals as SYSTEM, runs OSOT finalize and shuts down. Afterwards: snapshot and Push Image in Horizon Console.'
        'i9' = 'Blocks automatic updates, runs OSOT optimize and finalize. Afterwards: snapshot and Push Image in Horizon Console.'
        'iU' = 'Restores the update mechanisms blocked by Seal (needed before manual changes).'
        'q.continue' = 'Continue?'
        'q.snapshot' = 'Did you take a VM snapshot "pre-generalize" in vCenter?'
        'snapshot.no'= 'Take the snapshot first - a failed Sysprep can leave the VM unbootable.'
        'q.shutdown' = 'Shut down the VM at the end?'
        'q.cleanup'  = 'Clean up the image (temp files, update cache, DISM)?'
        'q.reboot'   = 'Reboot now?'
        'dl.warn'    = 'Some downloads failed - the update continues with the files already in C:\install.'
        'yes'        = 'y'; 'yn' = 'Y/n'; 'ny' = 'y/N'
        'ok'         = 'Done - OK.'
        'err'        = 'Finished with errors, exit code {0}. Details in the log.'
        'warn'       = 'Finished with warnings (exit code 1).'
        'logs'       = 'Logs: {0}'
        'press'      = 'Press Enter to return to the menu'
        'missing'    = 'File not found: {0} - copy the whole install folder to C:\install.'
        'running'    = 'Running: {0}'
    }
    pl = @{
        'title'      = 'VDI-ImageMaint - złoty obraz Omnissa Horizon'
        'sec.first'  = 'PIERWSZA KONFIGURACJA'
        'sec.build'  = 'BUDOWA NOWEGO OBRAZU (raz na wydanie Windows, VM w trybie audytu)'
        'sec.month'  = 'AKTUALIZACJA MIESIĘCZNA (istniejący obraz)'
        'sec.tools'  = 'NARZĘDZIA'
        'm1' = 'Kreator konfiguracji (profil, Office, FSLogix, OSOT, aplikacje)'
        'm2' = 'Pobierz darmowe pakiety (Office, Teams, FSLogix, OneDrive, VMware Tools...)'
        'm3' = 'Plan - co zostanie zainstalowane (niczego nie zmienia)'
        'm4' = 'Aktualizacje i pakiety (automatyczne restarty)'
        'm5' = 'Optymalizacja OSOT (potem restart)'
        'm6' = 'Kontrola gotowości do Sysprep'
        'm7' = 'Generalize (Sysprep) i automatyczne dokończenie budowy'
        'm8' = 'Wszystko automatycznie: pobranie, aktualizacja, restarty, zamknięcie, wyłączenie'
        'm9' = 'Tylko zamknięcie obrazu (Seal) - po ręcznych zmianach'
        'mS' = 'Stan'; 'mU' = 'Odblokuj'; 'mI' = 'Spis pakietów'; 'mV' = 'Sprawdź manifest'; 'mL' = 'Otwórz logi'; 'mQ' = 'Wyjście'
        'mB' = 'Nośnik dla nowej VM (ISO: instalacja bez pytań do trybu audytu + C:\install)'
        'mO' = 'Nośnik OSDCloud (WinPE pobiera Windows; wymaga ADK i modułu OSD)'
        'mC' = 'vCenter: utwórz VM złotego obrazu i uruchom instalację (vcenter.json)'
        'mR' = 'vCenter: wydanie do puli (puste CD, bez vTPM, snapshot) - VM wyłączona'
        'q.osd' = 'Użyć nośnika OSDCloud (VDI-OSDCloud.iso) zamiast VDI-Build.iso?'
        'mP' = 'Horizon: Push Image najnowszego snapshotu Gold do pul (vcenter.json Horizon)'
        'q.push' = 'Wypchnąć obraz teraz? Użytkownicy - wg polityki wylogowania z vcenter.json'
        'choice'     = 'Wybierz krok i naciśnij Enter'
        'i1' = 'Odpowiadaj na pytania. Enter przyjmuje wartość domyślną w nawiasie. Przed zmianą każdego pliku powstaje kopia.'
        'i2' = 'Pobiera pakiety niewymagające logowania do właściwych folderów, sprawdza podpisy i rozpakowuje archiwa. Pakiety wymagające logowania (OSOT, agenty Horizon) zostaną wypisane na końcu.'
        'i4' = 'Instaluje pakiety, Office, Teams, aplikacje winget i aktualizacje Windows. VM sama się restartuje i kontynuuje po zalogowaniu (otworzy się nowe okno).'
        'i5' = 'OSOT optymalizuje obraz według OSOT\Optimize.json. Przed krokiem 6 zrestartuj VM.'
        'i6' = 'Sprawdza wszystkie znane przyczyny błędów Sysprep. Niczego nie zmienia.'
        'i7' = 'Uruchamia Sysprep. Po OOBE VM sama się zaloguje, zainstaluje agenty Horizon, zrestartuje się w razie potrzeby, zamknie obraz i sfinalizuje. Skrypt zapyta o hasło administratora.'
        'i8' = 'Pobiera świeże pakiety, odblokowuje, aktualizuje z automatycznymi restartami, zamyka obraz jako SYSTEM, uruchamia OSOT Finalize i wyłącza VM. Potem: snapshot i Push Image w Horizon Console.'
        'i9' = 'Blokuje automatyczne aktualizacje, uruchamia OSOT Optimize i Finalize. Potem: snapshot i Push Image w Horizon Console.'
        'iU' = 'Przywraca mechanizmy aktualizacji zablokowane przez Seal (potrzebne przed ręcznymi zmianami).'
        'q.continue' = 'Kontynuować?'
        'q.snapshot' = 'Czy zrobiłeś snapshot VM "pre-generalize" w vCenter?'
        'snapshot.no'= 'Najpierw zrób snapshot - nieudany Sysprep może zostawić VM, która nie startuje.'
        'q.shutdown' = 'Wyłączyć VM na końcu?'
        'q.cleanup'  = 'Wyczyścić obraz (pliki tymczasowe, pamięć aktualizacji, DISM)?'
        'q.reboot'   = 'Zrestartować teraz?'
        'dl.warn'    = 'Część pobrań się nie udała - aktualizacja kontynuuje z plikami, które już są w C:\install.'
        'yes'        = 't'; 'yn' = 'T/n'; 'ny' = 't/N'
        'ok'         = 'Zakończono - OK.'
        'err'        = 'Zakończono z błędami, kod {0}. Szczegóły w logu.'
        'warn'       = 'Zakończono z ostrzeżeniami (kod 1).'
        'logs'       = 'Logi: {0}'
        'press'      = 'Naciśnij Enter, aby wrócić do menu'
        'missing'    = 'Nie znaleziono pliku: {0} - skopiuj cały folder install do C:\install.'
        'running'    = 'Uruchamiam: {0}'
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
function Show-Info {
    param([string]$Text)
    Write-Host ''
    Write-Host ('-' * 70) -ForegroundColor DarkCyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ('-' * 70) -ForegroundColor DarkCyan
}

function Read-YesNo {
    param([string]$Question, [bool]$Default = $true)
    $a = Read-Host ('{0} [{1}]' -f $Question, $(if ($Default) { T 'yn' } else { T 'ny' }))
    if (-not $a) { return $Default }
    return ($a.Trim().ToLower() -in @((T 'yes'), 'y', 't', 'tak', 'yes'))
}

function Wait-Return { [void](Read-Host (T 'press')) }

function Invoke-Tool {
    # Separate Windows PowerShell process: the tool uses exit codes, transcripts and may reboot the VM.
    # -NoWait: return the exit code without the result message (used when another step follows).
    param([string]$Script, [string[]]$Arguments, [switch]$NoWait)
    if (-not (Test-Path -LiteralPath $Script)) { Write-Host (T 'missing' @($Script)) -ForegroundColor Red; Wait-Return; return 1 }
    Write-Host ''
    Write-Host (T 'running' @(((Split-Path $Script -Leaf), ($Arguments -join ' ')) -join ' ')) -ForegroundColor DarkGray
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Start-Process -NoNewWindow: the tool writes straight to this console (live output, prompts) instead of
    # into the pipeline; the tools speak the same language as the menu
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + @($Arguments) + @('-Language', $Lang)
    # the tool works on the folder the menu lives in (C:\install, or wherever it was copied)
    if ($Script -eq $Tool) { $argList += @('-InstallDir', $Root) }
    $argLine = ($argList | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' '
    $rc = (Start-Process -FilePath $ps -ArgumentList $argLine -NoNewWindow -Wait -PassThru).ExitCode
    if ($NoWait) { return $rc }
    Write-Host ''
    if ($rc -eq 0) { Write-Host (T 'ok') -ForegroundColor Green }
    elseif ($rc -eq 1 -and (Split-Path $Script -Leaf) -eq 'Test-SysprepReadiness.ps1') { Write-Host (T 'warn') -ForegroundColor Yellow }
    else { Write-Host (T 'err' @($rc)) -ForegroundColor Red }
    Write-Host (T 'logs' @($LogDir)) -ForegroundColor DarkGray
    Wait-Return
    return $rc
}

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ('  ' + (T 'title')) -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    $sections = @(
        @('sec.first', @('1', '2', '3')),
        @('sec.build', @('4', '5', '6', '7')),
        @('sec.month', @('8', '9'))
    )
    foreach ($s in $sections) {
        Write-Host ''
        Write-Host ('  ' + (T $s[0])) -ForegroundColor Yellow
        foreach ($k in $s[1]) { Write-Host ('    {0}. {1}' -f $k, (T "m$k")) }
    }
    Write-Host ''
    Write-Host ('  ' + (T 'sec.tools')) -ForegroundColor Yellow
    Write-Host ('    S. {0}    U. {1}    I. {2}    V. {3}' -f (T 'mS'), (T 'mU'), (T 'mI'), (T 'mV'))
    Write-Host ('    B. {0}' -f (T 'mB'))
    Write-Host ('    O. {0}' -f (T 'mO'))
    Write-Host ('    C. {0}' -f (T 'mC'))
    Write-Host ('    R. {0}' -f (T 'mR'))
    Write-Host ('    P. {0}' -f (T 'mP'))
    Write-Host ('    L. {0}    Q. {1}' -f (T 'mL'), (T 'mQ'))
    Write-Host ''
}

# =====================================================================
#  MENU LOOP
# =====================================================================
while ($true) {
    Show-Menu
    $c = [string](Read-Host (T 'choice'))
    $null = switch ($c.Trim().ToUpper()) {
        '1' { Show-Info (T 'i1'); Invoke-Tool $Tool @('-Mode', 'Configure') }
        '2' { Show-Info (T 'i2'); Invoke-Tool $Tool @('-Mode', 'Download') }
        '3' { Invoke-Tool $Tool @('-Mode', 'PackageList') }
        '4' {
            Show-Info (T 'i4')
            if (Read-YesNo (T 'q.continue')) { Invoke-Tool $Tool @('-Mode', 'Update', '-AutoReboot') }
        }
        '5' {
            Show-Info (T 'i5')
            if (Read-YesNo (T 'q.continue')) {
                Invoke-Tool $Tool @('-Mode', 'Optimize')
                if (Read-YesNo (T 'q.reboot')) { Restart-Computer -Force }
            }
        }
        '6' { Show-Info (T 'i6'); Invoke-Tool $Check @('-InstallDir', $Root) }
        '7' {
            Show-Info (T 'i7')
            if (-not (Read-YesNo (T 'q.snapshot') $false)) { Write-Host (T 'snapshot.no') -ForegroundColor Yellow; Wait-Return; break }
            $a = @('-Mode', 'Generalize', '-SnapshotConfirmed')
            if (Read-YesNo (T 'q.shutdown')) { $a += '-Shutdown' }
            Invoke-Tool $Tool $a
        }
        '8' {
            Show-Info (T 'i8')
            if (Read-YesNo (T 'q.continue')) {
                $a = @('-Mode', 'Update', '-AutoReboot', '-ThenSeal', '-Shutdown')
                if (Read-YesNo (T 'q.cleanup') $false) { $a += '-Cleanup' }
                # fresh Office/Teams/OneDrive/FSLogix first; a failed download does not stop the monthly cycle
                if ((Invoke-Tool $Tool @('-Mode', 'Download') -NoWait) -ne 0) { Write-Host (T 'dl.warn') -ForegroundColor Yellow }
                Invoke-Tool $Tool $a
            }
        }
        '9' {
            Show-Info (T 'i9')
            $a = @('-Mode', 'Seal', '-AsSystem')
            if (Read-YesNo (T 'q.cleanup') $false) { $a += '-Cleanup' }
            if (Read-YesNo (T 'q.shutdown')) { $a += '-Shutdown' }
            Invoke-Tool $Tool $a
        }
        'B' { Invoke-Tool $Media @('-InstallDir', $Root) }
        'O' { Invoke-Tool $Media @('-InstallDir', $Root, '-Method', 'OSDCloud') }
        'C' {
            $m = $(if (Read-YesNo (T 'q.osd') $false) { 'OSDCloud' } else { 'Setup' })
            Invoke-Tool $VCenter @('-Action', 'New', '-Method', $m, '-InstallDir', $Root)
        }
        'R' { Invoke-Tool $VCenter @('-Action', 'Release', '-InstallDir', $Root) }
        'P' { if (Read-YesNo (T 'q.push') $false) { Invoke-Tool $Push @('-Action', 'Push', '-Wait', '-InstallDir', $Root) } }
        'S' { Invoke-Tool $Tool @('-Mode', 'Status') }
        'U' {
            Show-Info (T 'iU')
            if (Read-YesNo (T 'q.continue')) { Invoke-Tool $Tool @('-Mode', 'Unlock', '-AsSystem') }
        }
        'I' { Invoke-Tool $Tool @('-Mode', 'Inventory') }
        'V' { Invoke-Tool $Tool @('-Mode', 'Validate') }
        'L' {
            if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
            Start-Process explorer.exe -ArgumentList "`"$LogDir`""
        }
        'Q' { exit 0 }
    }
}
