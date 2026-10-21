#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Larch / Larix (xraylarch - XAS / XRF data analysis, Python) for all users on a Windows 11 VDI golden
    image (Horizon Instant Clone).

.DESCRIPTION
    The official Windows installer xraylarch-<YYYY-MM>-Windows-x86_64.exe is a conda "constructor" (NSIS) installer.
    Interactively it installs per user (C:\Users\<name>\xraylarch or %LOCALAPPDATA%\xraylarch); its post-install
    script runs "pip install xraylarch[larix]" from PyPI and "larch -m" (shortcuts on the Desktop / Start menu of
    the installing account only). On a golden image this script makes it an all-users install:

    0. Earlier per-user copies (Uninstall-xraylarch.exe in <profile>\xraylarch or <profile>\AppData\Local\xraylarch
       of every local profile) are removed with their own uninstaller, with their Desktop / Start menu "Larch" folder.
    1. Install / update: silent all-users install of the conda base environment into a fixed folder WITHOUT spaces
       (Larch requirement, default C:\xraylarch):
         /S /InstallationType=AllUsers /AddToPath=0 /RegisterPython=0 /NoShortcuts=1 /NoScripts=1 /KeepPkgCache=0 /D=<folder>
       A newer installer replaces the folder (conda installers do not upgrade in place).
    2. pip install xraylarch[larix] (needs internet access to PyPI) - after an install, with -Upgrade, or when the
       larch module cannot be imported. -Requirement pins a version, e.g. 'xraylarch[larix]==2026.3.1'.
    3. Clean-up: Desktop / Start menu "Larch" folders of the installing account (older installers ignore
       /NoScripts and run "larch -m"), the constructor's own Uninstall entry is hidden (ours is the visible one).
    4. Permissions: Users read + execute, only Administrators/SYSTEM write - users cannot pip-install into or
       "Update Larch" the shared environment; propagation to the existing files is verified.
    5. Launchers <folder>\vdi\*.cmd set the conda environment (PATH, CONDA_PREFIX) per process, ignore the user's
       own pip --user packages (PYTHONNOUSERSITE=1) and start in %USERPROFILE%. Start menu group "Larch" for all
       users (Larix, XRF Viewer, XRFMap Viewer, XRD1D Viewer, Sitka, Jupyter Lab, Larch CLI - those present).
       The "Update Larch" shortcut of the upstream installer is left out on purpose.
    6. Smoke test: python imports larch and wx with the launcher environment.
    7. Uninstall entry (DisplayVersion = xraylarch version) - detection for the VDI-ImageMaint manifest. A copy of
       this script in <folder>\vdi does the uninstall (works without C:\install).

    Per-user data (FSLogix container): %USERPROFILE%\.larch (settings, history, Feff runs), %USERPROFILE%\.matplotlib,
    %APPDATA%\jupyter. Nothing is written into the install folder at run time.

    Idempotent: the same installer is not reinstalled, steps 0 and 3-7 are re-applied. Supports -WhatIf.
    Works as an administrator and as SYSTEM (VDI-ImageMaint -AsSystem).

.PARAMETER Source
    Folder with the installer(s) or the path of one installer. Default: <C:\install>\Apps\Larch.
.PARAMETER Destination
    Install folder, no spaces. Default C:\xraylarch. Keep it fixed - shortcuts and launchers use it.
.PARAMETER Requirement
    pip requirement for Larch. Default 'xraylarch[larix]' (GUIs + Jupyter, as the official installer).
.PARAMETER Upgrade
    pip install --upgrade (newest xraylarch from PyPI without a new installer).
.PARAMETER Uninstall
    Runs the conda uninstaller and removes the folder, shortcuts and the Uninstall entry.
.PARAMETER Language
    auto (UI culture: pl -> Polish, everything else -> English), en, pl.

.EXAMPLE
    .\Install-Larch.ps1 -WhatIf
.EXAMPLE
    .\Install-Larch.ps1 -Source C:\install\Apps\Larch -Upgrade

.NOTES
    Version 1.0. Log: C:\ProgramData\VDI-ImageMaint\Logs\Larch_<date>.log (installer: LarchSetup_<date>.log,
    pip: LarchPip_<date>.log). Download: https://xraypy.github.io/xraylarch/installation.html. Docs: docs/demeter.md.
    Installer definition: https://github.com/xraypy/xraylarch/tree/master/installers/conda_constructor
    Options: https://conda.github.io/constructor/cli-options/
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Source = '',
    [string]$Destination = 'C:\xraylarch',
    [string]$Requirement = 'xraylarch[larix]',
    [switch]$Upgrade,
    [switch]$Uninstall,
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
        'hdr'          = 'Larch / Larix (xraylarch) - all-users VDI install | {0} | {1}'
        'exe.none'     = 'No xraylarch-<YYYY-MM>-Windows-x86_64.exe in {0} (download it: docs/downloads.md or -Mode Download)'
        'exe.found'    = 'Installer: {0} (release {1})'
        'dest.space'   = 'Destination {0} contains a space - Larch does not work from such a path'
        'state'        = 'Installed: {0} (installer {1}) | installer: {2} | folder: {3}'
        'state.none'   = 'none'
        'current'      = 'Installer {0} already installed - re-applying the configuration only'
        'running'      = 'Larch is running from {0} - stopping {1} process(es)'
        'old'          = 'Per-user install found in {0} - removing it (its uninstaller)'
        'old.left'     = 'Per-user install {0}: folder still present after its uninstaller - remove it by hand'
        'old.icons'    = '  removed the shortcuts folder of that profile: {0}'
        'replace'      = 'Removing the previous environment {0} (conda installers do not upgrade in place)'
        'install'      = 'Silent all-users install into {0} ...'
        'install.rc'   = 'Installer exit code {0} - see {1}'
        'install.bad'  = 'After the install {0} is missing - see {1}'
        'installed'    = 'Installed {0} -> {1}'
        'pip'          = 'pip install {0} (PyPI) ...'
        'pip.skip'     = 'Larch {0} importable - pip not needed (-Upgrade for the newest release)'
        'pip.rc'       = 'pip exit code {0} - see {1} (internet access to pypi.org / files.pythonhosted.org needed)'
        'pip.ok'       = 'pip done'
        'clean'        = 'Leftovers of the installing account'
        'clean.item'   = '  removed: {0}'
        'clean.none'   = '  nothing to remove'
        'acl'          = 'Permissions {0}: Users read + execute, Administrators / SYSTEM full'
        'acl.rc'       = 'icacls exit code {0} - permissions of {1} not changed'
        'acl.reset'    = '  {0} is still writable for users - resetting the files below {1} to inherited permissions'
        'acl.still'    = '  {0} is still writable for users - check the permissions of {1}'
        'launch'       = 'Launchers and Start menu ({0})'
        'launch.item'  = '  {0} -> {1}'
        'launch.miss'  = '  {0}: {1} missing - skipped'
        'smoke'        = 'Smoke test: python imports larch and wx'
        'smoke.ok'     = '  OK (xraylarch {0})'
        'smoke.bad'    = '  import larch, wx failed (exit {0}): {1}'
        'arp'          = 'Uninstall entry: {0} {1}'
        'uninst'       = 'Removing {0}'
        'uninst.run'   = 'Larch uninstaller: {0}'
        'uninst.none'  = 'Nothing to remove'
        'done'         = 'Done'
        'done.warn'    = 'Done with {0} warning(s)'
        'next'         = 'Next: log on to a test clone as an ordinary user (not the installing account), start Larix from the Start menu, read a data file, run a Feff calculation, then Seal + Push Image.'
    }
    pl = @{
        'hdr'          = 'Larch / Larix (xraylarch) - instalacja VDI dla wszystkich | {0} | {1}'
        'exe.none'     = 'Brak xraylarch-<RRRR-MM>-Windows-x86_64.exe w {0} (pobierz: docs/pl/downloads.md albo -Mode Download)'
        'exe.found'    = 'Instalator: {0} (wydanie {1})'
        'dest.space'   = 'Folder docelowy {0} zawiera spację - Larch nie działa z takiej ścieżki'
        'state'        = 'Zainstalowane: {0} (instalator {1}) | instalator: {2} | folder: {3}'
        'state.none'   = 'brak'
        'current'      = 'Instalator {0} jest już zainstalowany - tylko ponowne zastosowanie konfiguracji'
        'running'      = 'Larch działa z {0} - zatrzymuję procesy: {1}'
        'old'          = 'Znaleziono instalację per-user w {0} - usuwam ją (jej deinstalatorem)'
        'old.left'     = 'Instalacja per-user {0}: folder nadal istnieje po deinstalatorze - usuń go ręcznie'
        'old.icons'    = '  usunięto folder skrótów tego profilu: {0}'
        'replace'      = 'Usuwam poprzednie środowisko {0} (instalatory conda nie aktualizują w miejscu)'
        'install'      = 'Cicha instalacja dla wszystkich do {0} ...'
        'install.rc'   = 'Kod wyjścia instalatora {0} - zobacz {1}'
        'install.bad'  = 'Po instalacji brakuje {0} - zobacz {1}'
        'installed'    = 'Zainstalowano {0} -> {1}'
        'pip'          = 'pip install {0} (PyPI) ...'
        'pip.skip'     = 'Larch {0} się importuje - pip niepotrzebny (-Upgrade dla najnowszego wydania)'
        'pip.rc'       = 'Kod wyjścia pip {0} - zobacz {1} (potrzebny dostęp do pypi.org / files.pythonhosted.org)'
        'pip.ok'       = 'pip zakończony'
        'clean'        = 'Pozostałości konta instalującego'
        'clean.item'   = '  usunięto: {0}'
        'clean.none'   = '  nie ma czego usuwać'
        'acl'          = 'Uprawnienia {0}: Użytkownicy odczyt + wykonanie, Administratorzy / SYSTEM pełne'
        'acl.rc'       = 'Kod wyjścia icacls {0} - uprawnienia {1} nie zostały zmienione'
        'acl.reset'    = '  {0} nadal jest zapisywalny dla użytkowników - przywracam dziedziczone uprawnienia plików w {1}'
        'acl.still'    = '  {0} nadal jest zapisywalny dla użytkowników - sprawdź uprawnienia {1}'
        'launch'       = 'Launchery i menu Start ({0})'
        'launch.item'  = '  {0} -> {1}'
        'launch.miss'  = '  {0}: brak {1} - pominięto'
        'smoke'        = 'Test: python importuje larch i wx'
        'smoke.ok'     = '  OK (xraylarch {0})'
        'smoke.bad'    = '  import larch, wx nie działa (kod {0}): {1}'
        'arp'          = 'Wpis odinstalowania: {0} {1}'
        'uninst'       = 'Usuwam {0}'
        'uninst.run'   = 'Deinstalator Larch: {0}'
        'uninst.none'  = 'Nie ma czego usuwać'
        'done'         = 'Zakończono'
        'done.warn'    = 'Zakończono z ostrzeżeniami: {0}'
        'next'         = 'Dalej: zaloguj się na klonie testowym jako zwykły użytkownik (nie konto instalujące), uruchom Larix z menu Start, wczytaj plik danych, policz Feff, potem Seal + Push Image.'
    }
}

$Lang = $Language
if ($Lang -eq 'auto') { $Lang = $(if ((Get-UICulture).TwoLetterISOLanguageName -eq 'pl') { 'pl' } else { 'en' }) }

function T {
    # T 'key' arg0 arg1 ... (same call style as the module)
    param([string]$Key, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Arg)
    $s = $Strings[$Lang][$Key]
    if (-not $s) { $s = $Strings['en'][$Key] }
    if (-not $s) { return $Key }
    if ($Arg) { return ($s -f $Arg) }
    return $s
}

# =====================================================================
#  HELPERS
# =====================================================================
$LogDir = Join-Path $env:ProgramData 'VDI-ImageMaint\Logs'
New-Item -ItemType Directory -Path $LogDir -Force -WhatIf:$false | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:Warnings = 0

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'STEP')][string]$Level = 'INFO')
    $color = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERR = 'Red'; STEP = 'Cyan' }[$Level]
    if ($Level -eq 'STEP') { Write-Host '' }
    if ($Level -eq 'WARN') { $script:Warnings++ }
    Write-Host ('[{0}] [{1,-4}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $color
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($key) { return $key.GetValue($Name, $null) }
    return $null
}

function Get-ReleaseFromName {
    # xraylarch-2026-03-Windows-x86_64.exe -> 2026-03 ('2026-01orig' builds are not matched)
    param([string]$Name)
    if ($Name -match '^xraylarch-(\d{4}-\d{2})-Windows-x86_64') { return $Matches[1] }
    return ''
}

function Stop-LarchProcess {
    param([string]$Folder = $Destination)
    $procs = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($Folder + '\', [StringComparison]::OrdinalIgnoreCase) })
    if ($procs.Count) { Write-Log (T 'running' $Folder $procs.Count) WARN; $procs | Stop-Process -Force }
}

function Invoke-CondaUninstall {
    # NSIS uninstaller: _?=<folder> = run in place and wait (no copy to %TEMP%); it cannot delete itself then
    param([string]$Folder)
    $unins = Join-Path $Folder 'Uninstall-xraylarch.exe'
    if (Test-Path -LiteralPath $unins) {
        $null = Start-Process -FilePath $unins -ArgumentList "/S _?=$Folder" -Wait -PassThru
    }
    if (Test-Path -LiteralPath $Folder) { Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue }
    return -not (Test-Path -LiteralPath $Folder)
}

function Get-ProfileFolder {
    # Local profiles (ProfileList) - the per-user installer may have been run by any of them
    $list = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($k in @(Get-ChildItem -LiteralPath $list -ErrorAction SilentlyContinue)) {
        $p = [string]$k.GetValue('ProfileImagePath', '')
        if ($p) { [Environment]::ExpandEnvironmentVariables($p) }
    }
}

function Test-UserWritable {
    # True when Everyone / Authenticated Users / Users may write, delete or re-permission $Path
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $sids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')
    $mask = 0x500D0006L   # WriteData, AppendData, Delete, ChangePermissions, TakeOwnership, GENERIC_ALL, GENERIC_WRITE
    try {
        $rules = (Get-Acl -LiteralPath $Path).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
    } catch { return $false }
    foreach ($r in $rules) {
        if ([string]$r.AccessControlType -eq 'Allow' -and $sids -contains $r.IdentityReference.Value -and
            (([long][int]$r.FileSystemRights) -band $mask)) { return $true }
    }
    return $false
}

function Invoke-Icacls {
    param([string[]]$Arguments)
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & icacls.exe @Arguments 2>&1
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $eap
    return [pscustomobject]@{ Rc = $rc; Text = (($out | ForEach-Object { [string]$_ }) -join ' ').Trim() }
}

function Invoke-WithLarchEnv {
    # Runs $Block with the environment of the launchers (conda base activated, no user site-packages)
    param([scriptblock]$Block)
    $saved = @{}
    $set = @{ Path = (($EnvPath -join ';') + ';' + $env:Path); CONDA_PREFIX = $Destination; PYTHONNOUSERSITE = '1'
              PIP_DISABLE_PIP_VERSION_CHECK = '1'; PIP_NO_INPUT = '1' }
    foreach ($n in $set.Keys) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process'); [Environment]::SetEnvironmentVariable($n, $set[$n], 'Process') }
    try { & $Block } finally {
        foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
    }
}

function Get-LarchVersion {
    # xraylarch version importable from the environment ('' = not importable); also returns the output
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = Invoke-WithLarchEnv { & $PythonExe -c 'import larch, wx; print(larch.__version__)' 2>&1 }
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $eap
    $std = (@($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) | Select-Object -Last 1)
    $all = (($out | ForEach-Object { [string]$_ }) -join ' ').Trim()
    return [pscustomobject]@{ Rc = $rc; Version = $(if ($rc -eq 0 -and $std) { ([string]$std).Trim() } else { '' }); Text = $all }
}

# =====================================================================
#  CONFIGURATION
# =====================================================================
$Destination = $Destination.TrimEnd('\')
if (-not $Source) { $Source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Apps\Larch' }   # PS 5.1: $PSScriptRoot is empty in param defaults
$ProductName = 'Larch / Larix (xraylarch)'
$ArpKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VDI-ImageMaint-Larch'
$MenuDir     = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Larch'
$VdiDir      = Join-Path $Destination 'vdi'
$SelfCopy    = Join-Path $VdiDir 'Install-Larch.ps1'
$PythonExe   = Join-Path $Destination 'python.exe'
$ScriptsDir  = Join-Path $Destination 'Scripts'
$IconDir     = Join-Path $Destination 'Lib\site-packages\larch\icons'
# PATH of an activated conda base environment (conda activate / the installer's post_install_windows.bat)
$EnvPath     = @('', 'Library\mingw-w64\bin', 'Library\usr\bin', 'Library\bin', 'Scripts', 'bin') |
    ForEach-Object { if ($_) { Join-Path $Destination $_ } else { $Destination } }

# Start menu entries (larch.apps.LarchApps of xraylarch, without "Update Larch"): name, console script, icon, window
$Apps = @(
    @{ Name = 'Larix';         Exe = 'larix.exe';            Icon = 'onecone';    Style = 7; Desc = 'XANES and EXAFS Analysis GUI for Larch' }
    @{ Name = 'XRF Viewer';    Exe = 'larch_xrf.exe';        Icon = 'ptable';     Style = 7; Desc = 'X-ray Fluorescence Data Viewing and Analysis' }
    @{ Name = 'XRFMap Viewer'; Exe = 'gse_mapviewer.exe';    Icon = 'gse_xrfmap'; Style = 7; Desc = 'XRFMap Viewing and Analysis' }
    @{ Name = 'XRD1D Viewer';  Exe = 'larch_xrd1d.exe';      Icon = 'larch';      Style = 7; Desc = 'X-ray Diffraction Data Viewing' }
    @{ Name = 'Sitka';         Exe = 'larch_sitka.exe';      Icon = 'sitka';      Style = 7; Desc = 'Hierarchical Data Viewer' }
    @{ Name = 'Jupyter Lab';   Exe = 'larch_jupyterlab.exe'; Icon = 'jupyter';    Style = 1; Desc = 'Jupyter Lab with Larch' }
    @{ Name = 'Larch CLI';     Exe = 'larch.exe';            Icon = 'larch';      Style = 1; Desc = 'Larch command line' }
)

# =====================================================================
#  START
# =====================================================================
$log = Join-Path $LogDir "Larch_$Stamp.log"
Start-Transcript -Path $log -Force -WhatIf:$false -Confirm:$false | Out-Null
try {
    Write-Log (T 'hdr' $env:COMPUTERNAME ([Security.Principal.WindowsIdentity]::GetCurrent().Name)) STEP
    if ($Destination -match '\s') { throw (T 'dest.space' $Destination) }

    # ---------- uninstall ----------
    if ($Uninstall) {
        Stop-LarchProcess
        if ((Test-Path -LiteralPath $Destination) -and $PSCmdlet.ShouldProcess($Destination, (T 'uninst.run' $Destination))) {
            Write-Log (T 'uninst.run' $Destination)
            if (Invoke-CondaUninstall $Destination) { Write-Log (T 'uninst' $Destination) OK } else { Write-Log (T 'old.left' $Destination) WARN }
        }
        $items = @(@($MenuDir, $ArpKey) | Where-Object { Test-Path $_ })
        if (-not $items.Count -and -not (Test-Path -LiteralPath $Destination)) { Write-Log (T 'uninst.none') OK }
        foreach ($it in $items) {
            if ($PSCmdlet.ShouldProcess($it, (T 'uninst' $it))) { Remove-Item -LiteralPath $it -Recurse -Force; Write-Log (T 'uninst' $it) OK }
        }
    } else {

    # ---------- 1. installer ----------
    $exe = $null
    if (Test-Path $Source -PathType Leaf) { $exe = Get-Item $Source }
    elseif (Test-Path $Source) {
        $exe = Get-ChildItem -Path $Source -File -Filter 'xraylarch-*-Windows-x86_64.exe' |
            Where-Object { Get-ReleaseFromName $_.Name } |
            Sort-Object @{ Expression = { Get-ReleaseFromName $_.Name }; Descending = $true } | Select-Object -First 1
    }
    if (-not $exe -or -not (Get-ReleaseFromName $exe.Name)) { throw (T 'exe.none' $Source) }
    $release = Get-ReleaseFromName $exe.Name
    Write-Log (T 'exe.found' $exe.FullName $release)

    $installed    = [string](Get-RegValue $ArpKey 'DisplayVersion')
    $installedRel = [string](Get-RegValue $ArpKey 'InstallerRelease')
    Write-Log (T 'state' $(if ($installed) { $installed } else { T 'state.none' }) $(if ($installedRel) { $installedRel } else { '-' }) $release $Destination)

    # ---------- 0. earlier per-user copies (any local profile) ----------
    $profiles = @(Get-ProfileFolder)
    $old = @()
    foreach ($p in $profiles) { $old += Join-Path $p 'xraylarch'; $old += Join-Path $p 'AppData\Local\xraylarch' }
    $old = @($old | Where-Object { $_ -ne $Destination -and (Test-Path -LiteralPath (Join-Path $_ 'Uninstall-xraylarch.exe')) } | Sort-Object -Unique)
    foreach ($o in $old) {
        if (-not $PSCmdlet.ShouldProcess($o, (T 'old' $o))) { continue }
        Write-Log (T 'old' $o) WARN
        Stop-LarchProcess -Folder $o
        if (-not (Invoke-CondaUninstall $o)) { Write-Log (T 'old.left' $o) WARN }
        # "larch -m" (pyshortcuts) of that profile: Desktop\Larch and Start Menu\Programs\Larch
        foreach ($p in $profiles) {
            if (-not $o.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            foreach ($d in @((Join-Path $p 'Desktop\Larch'), (Join-Path $p 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Larch'))) {
                if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force; Write-Log (T 'old.icons' $d) }
            }
        }
    }

    $fresh = $false
    if ($installedRel -eq $release -and (Test-Path $PythonExe)) {
        Write-Log (T 'current' $release) OK
    } elseif ($PSCmdlet.ShouldProcess($Destination, "$($exe.Name) -> $Destination")) {
        Stop-LarchProcess
        if (Test-Path -LiteralPath $Destination) {
            # the NSIS installer refuses a non-empty folder; the old environment goes completely (incl. vdi\)
            Write-Log (T 'replace' $Destination) WARN
            if (-not (Invoke-CondaUninstall $Destination)) { throw (T 'old.left' $Destination) }
        }
        $setupLog = Join-Path $LogDir "LarchSetup_$Stamp.log"
        Unblock-File -LiteralPath $exe.FullName
        Write-Log (T 'install' $Destination)
        # flags without a value first, /D= last and unquoted (NSIS); /NoScripts=1 skips the post-install script
        # (pip from PyPI + desktop icons of this account) - step 2 does the pip part with a log and an exit code
        $al = "/S /InstallationType=AllUsers /AddToPath=0 /RegisterPython=0 /NoShortcuts=1 /NoScripts=1 /KeepPkgCache=0 /D=$Destination"
        $sp = @{ FilePath = $exe.FullName; ArgumentList = $al; Wait = $true; PassThru = $true; NoNewWindow = $true
                 RedirectStandardOutput = $setupLog; RedirectStandardError = "$setupLog.err" }
        $rc = (Start-Process @sp).ExitCode
        if ($rc -ne 0) { throw (T 'install.rc' $rc $setupLog) }
        if (-not (Test-Path $PythonExe)) { throw (T 'install.bad' $PythonExe $setupLog) }
        Write-Log (T 'installed' $exe.Name $Destination) OK
        $fresh = $true
    }

    # -WhatIf before the first install: nothing to configure yet
    if (Test-Path $PythonExe) {

    # ---------- 2. pip install xraylarch[larix] ----------
    Write-Log (T 'pip' $Requirement) STEP
    $lv = Get-LarchVersion
    if (-not $fresh -and -not $Upgrade -and $lv.Version) { Write-Log (T 'pip.skip' $lv.Version) OK }
    elseif ($PSCmdlet.ShouldProcess($Destination, "pip install $Requirement")) {
        $pipLog = Join-Path $LogDir "LarchPip_$Stamp.log"
        $pipArgs = @('-m', 'pip', 'install', '--no-cache-dir', '--no-warn-script-location')
        if ($Upgrade) { $pipArgs += '--upgrade' }
        $pipArgs += ('"{0}"' -f $Requirement)
        $sp = @{ FilePath = $PythonExe; ArgumentList = ($pipArgs -join ' '); Wait = $true; PassThru = $true; NoNewWindow = $true
                 WorkingDirectory = $Destination; RedirectStandardOutput = $pipLog; RedirectStandardError = "$pipLog.err" }
        $pipRc = Invoke-WithLarchEnv { (Start-Process @sp).ExitCode }
        if ($pipRc -ne 0) { throw (T 'pip.rc' $pipRc $pipLog) }
        Write-Log (T 'pip.ok') OK
    }

    # ---------- 3. leftovers of the installing account ----------
    Write-Log (T 'clean') STEP
    $removed = 0
    $junk = @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Larch'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'Larch'))
    foreach ($j in $junk) {
        if ((Test-Path -LiteralPath $j) -and $PSCmdlet.ShouldProcess($j, 'remove')) { Remove-Item -LiteralPath $j -Recurse -Force; $removed++; Write-Log (T 'clean.item' $j) }
    }
    # the constructor's own Uninstall entry (HKLM for AllUsers): hidden, ours is the visible one
    $un = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($k in @(Get-ChildItem -LiteralPath $un -ErrorAction SilentlyContinue)) {
        if ($k.PSChildName -eq 'VDI-ImageMaint-Larch') { continue }
        $us = [string]$k.GetValue('UninstallString', '')
        if ($us -like "*$Destination\Uninstall-xraylarch.exe*" -and $k.GetValue('SystemComponent', 0) -ne 1 -and $PSCmdlet.ShouldProcess($k.Name, 'SystemComponent=1')) {
            New-ItemProperty -LiteralPath $k.PSPath -Name 'SystemComponent' -Value 1 -PropertyType DWord -Force | Out-Null
            $removed++; Write-Log (T 'clean.item' "$($k.PSChildName) (SystemComponent=1)")
        }
    }
    if (-not $removed) { Write-Log (T 'clean.none') }

    # ---------- 4. permissions ----------
    Write-Log (T 'acl' $Destination) STEP
    if ($PSCmdlet.ShouldProcess($Destination, 'icacls')) {
        # SIDs: SYSTEM, Administrators, Users (language-neutral). Inheritable ACEs propagate to the existing files.
        $ic = Invoke-Icacls @($Destination, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/Q')
        if ($ic.Rc -ne 0) { Write-Log (T 'acl.rc' $ic.Rc $Destination) WARN; Write-Log $ic.Text }
        else {
            $sample = @($PythonExe, (Join-Path $ScriptsDir 'larix.exe')) | Where-Object { Test-UserWritable $_ } | Select-Object -First 1
            if ($sample) {
                Write-Log (T 'acl.reset' $sample $Destination) WARN
                $ic = Invoke-Icacls @((Join-Path $Destination '*'), '/reset', '/T', '/C', '/Q')
                if ($ic.Rc -ne 0 -or (Test-UserWritable $sample)) { Write-Log (T 'acl.still' $sample $Destination) WARN; Write-Log $ic.Text }
            }
        }
    }

    # ---------- 5. launchers, Start menu ----------
    Write-Log (T 'launch' $MenuDir) STEP
    if ($PSCmdlet.ShouldProcess($VdiDir, 'launchers + shortcuts')) {
        New-Item -ItemType Directory -Path $VdiDir, $MenuDir -Force | Out-Null
        # the Uninstall entry runs this copy (C:\install may be gone by then)
        if ($PSCommandPath -and $PSCommandPath -ne $SelfCopy) { Copy-Item -LiteralPath $PSCommandPath -Destination $SelfCopy -Force }
        $sh = New-Object -ComObject WScript.Shell
        foreach ($a in $Apps) {
            $target = Join-Path $ScriptsDir $a.Exe
            $lnkPath = Join-Path $MenuDir "$($a.Name).lnk"
            $cmd = Join-Path $VdiDir ($a.Name.Replace(' ', '-') + '.cmd')
            if (-not (Test-Path $target)) {
                Write-Log (T 'launch.miss' $a.Name $target)
                foreach ($stale in $lnkPath, $cmd) { if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force } }
                continue
            }
            $text = @(
                '@echo off'
                'rem VDI-ImageMaint Install-Larch.ps1 - all-users launcher: conda base environment per process, no user site-packages'
                'setlocal'
                ('set "PATH={0};%PATH%"' -f ($EnvPath -join ';'))
                ('set "CONDA_PREFIX={0}"' -f $Destination)
                'set "PYTHONNOUSERSITE=1"'
                'cd /d "%USERPROFILE%"'
                ('"{0}" %*' -f $target)
            )
            [IO.File]::WriteAllText($cmd, (($text -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
            $lnk = $sh.CreateShortcut($lnkPath)
            $lnk.TargetPath = $cmd
            $lnk.WorkingDirectory = '%USERPROFILE%'
            $lnk.WindowStyle = $a.Style   # 7 = minimized console behind the wx GUI, 1 = console programs
            $ico = Join-Path $IconDir "$($a.Icon).ico"
            if (Test-Path $ico) { $lnk.IconLocation = "$ico,0" }
            $lnk.Description = $a.Desc
            $lnk.Save()
            Write-Log (T 'launch.item' $a.Name $cmd)
        }
    }

    # ---------- 6. smoke test ----------
    Write-Log (T 'smoke') STEP
    $lv = Get-LarchVersion
    if ($lv.Version) { Write-Log (T 'smoke.ok' $lv.Version) OK } else { Write-Log (T 'smoke.bad' $lv.Rc $lv.Text) WARN }
    $version = $(if ($lv.Version) { $lv.Version } else { $release })

    # ---------- 7. Uninstall entry ----------
    if ($PSCmdlet.ShouldProcess($ArpKey, "DisplayVersion=$version")) {
        if (-not (Test-Path $ArpKey)) { New-Item -Path $ArpKey -Force | Out-Null }
        $uninst = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Destination "{1}" -Uninstall' -f $SelfCopy, $Destination
        $vals = [ordered]@{
            DisplayName = $ProductName; DisplayVersion = $version; InstallerRelease = $release; Publisher = 'xraypy (Matt Newville)'
            InstallLocation = $Destination; DisplayIcon = (Join-Path $IconDir 'onecone.ico'); Comments = 'xraylarch conda environment, all users (VDI-ImageMaint)'
            UninstallString = $uninst; QuietUninstallString = $uninst; URLInfoAbout = 'https://xraypy.github.io/xraylarch/'
        }
        foreach ($k in $vals.Keys) { New-ItemProperty -Path $ArpKey -Name $k -Value ([string]$vals[$k]) -PropertyType String -Force | Out-Null }
        foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty -Path $ArpKey -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
        Write-Log (T 'arp' $ProductName $version) OK
    }
    Write-Log (T 'next')
    }   # Test-Path $PythonExe
    }   # not -Uninstall

    if ($script:Warnings) { Write-Log (T 'done.warn' $script:Warnings) WARN } else { Write-Log (T 'done') OK }
    $exit = 0
} catch {
    Write-Log $_.Exception.Message ERR
    $exit = 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}
exit $exit
