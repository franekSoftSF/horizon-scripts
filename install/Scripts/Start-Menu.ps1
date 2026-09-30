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
        'm2' = 'Plan - what will be installed (changes nothing)'
        'm3' = 'Updates and packages (automatic reboots)'
        'm4' = 'OSOT optimization (then reboot)'
        'm5' = 'Sysprep readiness check'
        'm6' = 'Generalize (Sysprep) and finish the build automatically'
        'm7' = 'Everything automatically: update, reboots, seal, shut down'
        'm8' = 'Seal only (block updates, finalize) - after manual changes'
        'mS' = 'Status'; 'mU' = 'Unlock'; 'mI' = 'Inventory'; 'mL' = 'Open logs'; 'mQ' = 'Quit'
        'choice'     = 'Select a step and press Enter'
        'i1' = 'Answer the questions. Enter accepts the default in brackets. Every file is backed up first.'
        'i3' = 'Installs packages, Office, Teams, winget apps and Windows updates. The VM reboots by itself and continues after logon (a new window opens).'
        'i4' = 'OSOT optimizes the image with OSOT\Optimize.json. Reboot before step 5.'
        'i5' = 'Checks every known cause of Sysprep failures. Nothing is changed.'
        'i6' = 'Runs Sysprep. After OOBE the VM logs on automatically, installs the Horizon agents, reboots as needed, seals and finalizes. You will be asked for the administrator password.'
        'i7' = 'Unlock, updates with automatic reboots, then seal as SYSTEM, OSOT finalize and shut down. Afterwards: snapshot and Push Image in Horizon Console.'
        'i8' = 'Blocks automatic updates, runs OSOT optimize and finalize. Afterwards: snapshot and Push Image in Horizon Console.'
        'iU' = 'Restores the update mechanisms blocked by Seal (needed before manual changes).'
        'q.continue' = 'Continue?'
        'q.snapshot' = 'Did you take a VM snapshot "pre-generalize" in vCenter?'
        'snapshot.no'= 'Take the snapshot first - a failed Sysprep can leave the VM unbootable.'
        'q.shutdown' = 'Shut down the VM at the end?'
        'q.cleanup'  = 'Clean up the image (temp files, update cache, DISM)?'
        'q.reboot'   = 'Reboot now?'
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
        'm2' = 'Plan - co zostanie zainstalowane (niczego nie zmienia)'
        'm3' = 'Aktualizacje i pakiety (automatyczne restarty)'
        'm4' = 'Optymalizacja OSOT (potem restart)'
        'm5' = 'Kontrola gotowości do Sysprep'
        'm6' = 'Generalize (Sysprep) i automatyczne dokończenie budowy'
        'm7' = 'Wszystko automatycznie: aktualizacja, restarty, zamknięcie, wyłączenie'
        'm8' = 'Tylko zamknięcie obrazu (Seal) - po ręcznych zmianach'
        'mS' = 'Stan'; 'mU' = 'Odblokuj'; 'mI' = 'Spis pakietów'; 'mL' = 'Otwórz logi'; 'mQ' = 'Wyjście'
        'choice'     = 'Wybierz krok i naciśnij Enter'
        'i1' = 'Odpowiadaj na pytania. Enter przyjmuje wartość domyślną w nawiasie. Przed zmianą każdego pliku powstaje kopia.'
        'i3' = 'Instaluje pakiety, Office, Teams, aplikacje winget i aktualizacje Windows. VM sama się restartuje i kontynuuje po zalogowaniu (otworzy się nowe okno).'
        'i4' = 'OSOT optymalizuje obraz według OSOT\Optimize.json. Przed krokiem 5 zrestartuj VM.'
        'i5' = 'Sprawdza wszystkie znane przyczyny błędów Sysprep. Niczego nie zmienia.'
        'i6' = 'Uruchamia Sysprep. Po OOBE VM sama się zaloguje, zainstaluje agenty Horizon, zrestartuje się w razie potrzeby, zamknie obraz i sfinalizuje. Skrypt zapyta o hasło administratora.'
        'i7' = 'Odblokowanie, aktualizacje z automatycznymi restartami, zamknięcie obrazu jako SYSTEM, OSOT Finalize i wyłączenie. Potem: snapshot i Push Image w Horizon Console.'
        'i8' = 'Blokuje automatyczne aktualizacje, uruchamia OSOT Optimize i Finalize. Potem: snapshot i Push Image w Horizon Console.'
        'iU' = 'Przywraca mechanizmy aktualizacji zablokowane przez Seal (potrzebne przed ręcznymi zmianami).'
        'q.continue' = 'Kontynuować?'
        'q.snapshot' = 'Czy zrobiłeś snapshot VM "pre-generalize" w vCenter?'
        'snapshot.no'= 'Najpierw zrób snapshot - nieudany Sysprep może zostawić VM, która nie startuje.'
        'q.shutdown' = 'Wyłączyć VM na końcu?'
        'q.cleanup'  = 'Wyczyścić obraz (pliki tymczasowe, pamięć aktualizacji, DISM)?'
        'q.reboot'   = 'Zrestartować teraz?'
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
    # Separate Windows PowerShell process: the tool uses exit codes, transcripts and may reboot the VM
    param([string]$Script, [string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $Script)) { Write-Host (T 'missing' @($Script)) -ForegroundColor Red; Wait-Return; return }
    Write-Host ''
    Write-Host (T 'running' @(((Split-Path $Script -Leaf), ($Arguments -join ' ')) -join ' ')) -ForegroundColor DarkGray
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments
    $rc = $LASTEXITCODE
    Write-Host ''
    if ($rc -eq 0) { Write-Host (T 'ok') -ForegroundColor Green }
    elseif ($rc -eq 1 -and (Split-Path $Script -Leaf) -eq 'Test-SysprepReadiness.ps1') { Write-Host (T 'warn') -ForegroundColor Yellow }
    else { Write-Host (T 'err' @($rc)) -ForegroundColor Red }
    Write-Host (T 'logs' @($LogDir)) -ForegroundColor DarkGray
    Wait-Return
}

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ('  ' + (T 'title')) -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    $sections = @(
        @('sec.first', @('1', '2')),
        @('sec.build', @('3', '4', '5', '6')),
        @('sec.month', @('7', '8'))
    )
    foreach ($s in $sections) {
        Write-Host ''
        Write-Host ('  ' + (T $s[0])) -ForegroundColor Yellow
        foreach ($k in $s[1]) { Write-Host ('    {0}. {1}' -f $k, (T "m$k")) }
    }
    Write-Host ''
    Write-Host ('  ' + (T 'sec.tools')) -ForegroundColor Yellow
    Write-Host ('    S. {0}    U. {1}    I. {2}    L. {3}    Q. {4}' -f (T 'mS'), (T 'mU'), (T 'mI'), (T 'mL'), (T 'mQ'))
    Write-Host ''
}

# =====================================================================
#  MENU LOOP
# =====================================================================
while ($true) {
    Show-Menu
    $c = [string](Read-Host (T 'choice'))
    switch ($c.Trim().ToUpper()) {
        '1' { Show-Info (T 'i1'); Invoke-Tool $Tool @('-Mode', 'Configure') }
        '2' { Invoke-Tool $Tool @('-Mode', 'PackageList') }
        '3' {
            Show-Info (T 'i3')
            if (Read-YesNo (T 'q.continue')) { Invoke-Tool $Tool @('-Mode', 'Update', '-AutoReboot') }
        }
        '4' {
            Show-Info (T 'i4')
            if (Read-YesNo (T 'q.continue')) {
                Invoke-Tool $Tool @('-Mode', 'Optimize')
                if (Read-YesNo (T 'q.reboot')) { Restart-Computer -Force }
            }
        }
        '5' { Show-Info (T 'i5'); Invoke-Tool $Check @('-InstallDir', $Root) }
        '6' {
            Show-Info (T 'i6')
            if (-not (Read-YesNo (T 'q.snapshot') $false)) { Write-Host (T 'snapshot.no') -ForegroundColor Yellow; Wait-Return; break }
            $a = @('-Mode', 'Generalize', '-SnapshotConfirmed')
            if (Read-YesNo (T 'q.shutdown')) { $a += '-Shutdown' }
            Invoke-Tool $Tool $a
        }
        '7' {
            Show-Info (T 'i7')
            if (Read-YesNo (T 'q.continue')) {
                $a = @('-Mode', 'Update', '-AutoReboot', '-ThenSeal', '-Shutdown')
                if (Read-YesNo (T 'q.cleanup') $false) { $a += '-Cleanup' }
                Invoke-Tool $Tool $a
            }
        }
        '8' {
            Show-Info (T 'i8')
            $a = @('-Mode', 'Seal', '-AsSystem')
            if (Read-YesNo (T 'q.cleanup') $false) { $a += '-Cleanup' }
            if (Read-YesNo (T 'q.shutdown')) { $a += '-Shutdown' }
            Invoke-Tool $Tool $a
        }
        'S' { Invoke-Tool $Tool @('-Mode', 'Status') }
        'U' {
            Show-Info (T 'iU')
            if (Read-YesNo (T 'q.continue')) { Invoke-Tool $Tool @('-Mode', 'Unlock', '-AsSystem') }
        }
        'I' { Invoke-Tool $Tool @('-Mode', 'Inventory') }
        'L' {
            if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
            Start-Process explorer.exe -ArgumentList "`"$LogDir`""
        }
        'Q' { exit 0 }
    }
}
