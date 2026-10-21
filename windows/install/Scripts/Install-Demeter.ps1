#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Demeter (Athena, Artemis, Hephaestus, Atoms - XAS data analysis, Strawberry Perl) for all users on a
    Windows 11 VDI golden image (Horizon Instant Clone).

.DESCRIPTION
    The official installer (Demeter_<ver>_with_Strawberry_Perl_(64).exe, Inno Setup, PrivilegesRequired=lowest) is a
    per-user installer: default folder %APPDATA%\DemeterPerl, PATH and PGPLOT_DIR written to
    HKCU\SYSTEM\CurrentControlSet\Control\Session Manager\Environment (a key Windows never reads), file types in the
    HKCU root, Start menu group of the installing account. On a golden image every other user gets errors (no
    perl.exe in PATH, no PGPLOT_DIR, folder in someone else's profile). This script makes it an all-users install:

    0. Earlier per-user copies (Uninstall entry of the installing account, %APPDATA%\DemeterPerl of every local
       profile) are removed with their own uninstaller.
    1. Install / update: silent install into a fixed folder WITHOUT spaces (Strawberry Perl requirement,
       default C:\DemeterPerl). The installer's [Run] step relocation.pl.bat (runs in silent mode as well) rewrites
       the Perl paths to that folder - checked in step 5.
    2. Clean-up of the per-user leftovers of the installing account (PATH / PGPLOT_DIR values, the broken
       HKCU\.pl / .prj / .fpj keys, its Start menu group and desktop icons).
    3. Permissions: Users read + execute, only Administrators/SYSTEM write (C:\ subfolders inherit Modify for
       Authenticated Users by default); propagation to the existing files is verified.
    4. Launchers <folder>\vdi\*.cmd set PATH (Demeter first, so other Perl/MinGW installs do not interfere) and
       PGPLOT_DIR for the process and create %APPDATA%\demeter (logs, stash - inside the FSLogix container).
       Start menu group "Demeter" for all users points to them. Optional: -AddToPath (machine PATH for command
       line use), -Associate (.prj -> Athena, .fpj -> Artemis in HKLM).
    5. Smoke test: the bundled perl.exe loads the Demeter module with the launcher environment and its Config
       prefix points to the install folder (relocation done).
    6. Uninstall entry (DisplayVersion = Demeter version) - detection for the VDI-ImageMaint manifest. A copy of
       this script in <folder>\vdi does the uninstall (works without C:\install).

    Idempotent: when the version is already installed only steps 0 and 2-6 are re-applied. Supports -WhatIf.
    Works as an administrator and as SYSTEM (VDI-ImageMaint -AsSystem).

.PARAMETER Source
    Folder with the installer(s) or the path of one installer. Default: <C:\install>\Apps\Demeter.
.PARAMETER Destination
    Install folder, no spaces. Default C:\DemeterPerl. Keep it fixed - shortcuts and launchers use it.
.PARAMETER AddToPath
    Also appends perl\bin, perl\site\bin, c\bin to the machine PATH and sets PGPLOT_DIR machine-wide (command line
    use of Demeter / Perl). Off by default: Strawberry's c\bin (gcc, DLLs) in PATH can break other software.
.PARAMETER Associate
    Opens .prj (Athena project) with Athena and .fpj (Artemis project) with Artemis for all users. .prj is skipped
    when another program already owns it (e.g. ArcGIS / QGIS projection files).
.PARAMETER Uninstall
    Runs the Demeter uninstaller and removes the folder, shortcuts, associations and the Uninstall entry.
.PARAMETER Language
    auto (UI culture: pl -> Polish, everything else -> English), en, pl.

.EXAMPLE
    .\Install-Demeter.ps1 -WhatIf
.EXAMPLE
    .\Install-Demeter.ps1 -Source C:\install\Apps\Demeter -Associate

.NOTES
    Version 1.1. Log: C:\ProgramData\VDI-ImageMaint\Logs\Demeter_<date>.log (installer: DemeterSetup_<date>.log)
    Download: https://bruceravel.github.io/demeter/ (64-bit installer). Docs: docs/demeter.md.
    Installer script: https://github.com/bruceravel/demeter/blob/master/win/inno/strawberry.iss
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Source = '',
    [string]$Destination = 'C:\DemeterPerl',
    [switch]$AddToPath,
    [switch]$Associate,
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
        'hdr'          = 'Demeter (Athena / Artemis / Hephaestus) - all-users VDI install | {0} | {1}'
        'exe.none'     = 'No Demeter_*_with_Strawberry_Perl_(64).exe in {0} (download it: docs/downloads.md or -Mode Download)'
        'exe.found'    = 'Installer: {0} (version {1})'
        'exe.nover'    = 'Cannot read the Demeter version from {0} (expected Demeter_<version>_with_Strawberry_Perl_(64).exe)'
        'dest.space'   = 'Destination {0} contains a space - Strawberry Perl does not work from such a path'
        'state'        = 'Installed: {0} | installer: {1} | folder: {2}'
        'state.none'   = 'none'
        'current'      = 'Version {0} already installed - re-applying the configuration only'
        'running'      = 'Demeter is running from {0} - stopping {1} process(es)'
        'old'          = 'Per-user install found in {0} - removing it (its uninstaller)'
        'old.left'     = 'Per-user install {0}: folder still present after its uninstaller - remove it by hand'
        'old.group'    = '  removed the Start menu group of that profile: {0}'
        'unins.slow'   = 'Uninstaller of {0} did not finish within {1} s'
        'install'      = 'Silent install into {0} (all users) ...'
        'install.rc'   = 'Installer exit code {0} - see {1}'
        'install.bad'  = 'After the install {0} is missing - see {1}'
        'installed'    = 'Installed {0} -> {1}'
        'clean'        = 'Per-user leftovers of the installing account'
        'clean.item'   = '  removed: {0}'
        'clean.none'   = '  nothing to remove'
        'acl'          = 'Permissions {0}: Users read + execute, Administrators / SYSTEM full'
        'acl.rc'       = 'icacls exit code {0} - permissions of {1} not changed'
        'acl.reset'    = '  {0} is still writable for users - resetting the files below {1} to inherited permissions'
        'acl.still'    = '  {0} is still writable for users - check the permissions of {1}'
        'launch'       = 'Launchers and Start menu ({0})'
        'launch.item'  = '  {0} -> {1}'
        'launch.miss'  = '  {0}: {1} missing - skipped'
        'path.add'     = 'Machine PATH: added {0}'
        'path.same'    = 'Machine PATH: already contains the Demeter folders'
        'path.del'     = 'Machine PATH: removed the Demeter folders'
        'assoc'        = 'File association {0} -> {1}'
        'assoc.taken'  = 'File association {0} skipped: already owned by {1}'
        'smoke'        = 'Smoke test: perl.exe loads Demeter'
        'smoke.ok'     = '  OK (Demeter {0}, Perl prefix {1})'
        'smoke.bad'    = '  perl.exe -MDemeter failed (exit {0}): {1}'
        'smoke.reloc'  = '  Perl prefix is {0}, not below {1} - relocation.pl.bat of the installer did not run (see the installer log)'
        'arp'          = 'Uninstall entry: {0} {1}'
        'uninst'       = 'Removing {0}'
        'uninst.run'   = 'Demeter uninstaller: {0}'
        'uninst.none'  = 'Nothing to remove'
        'done'         = 'Done'
        'done.warn'    = 'Done with {0} warning(s)'
        'next'         = 'Next: log on to a test clone as an ordinary user (not the installing account), start Athena, Artemis and Hephaestus from the Start menu, open a project, then Seal + Push Image.'
    }
    pl = @{
        'hdr'          = 'Demeter (Athena / Artemis / Hephaestus) - instalacja VDI dla wszystkich | {0} | {1}'
        'exe.none'     = 'Brak Demeter_*_with_Strawberry_Perl_(64).exe w {0} (pobierz: docs/pl/downloads.md albo -Mode Download)'
        'exe.found'    = 'Instalator: {0} (wersja {1})'
        'exe.nover'    = 'Nie da się odczytać wersji Demeter z {0} (oczekiwane Demeter_<wersja>_with_Strawberry_Perl_(64).exe)'
        'dest.space'   = 'Folder docelowy {0} zawiera spację - Strawberry Perl nie działa z takiej ścieżki'
        'state'        = 'Zainstalowane: {0} | instalator: {1} | folder: {2}'
        'state.none'   = 'brak'
        'current'      = 'Wersja {0} jest już zainstalowana - tylko ponowne zastosowanie konfiguracji'
        'running'      = 'Demeter działa z {0} - zatrzymuję procesy: {1}'
        'old'          = 'Znaleziono instalację per-user w {0} - usuwam ją (jej deinstalatorem)'
        'old.left'     = 'Instalacja per-user {0}: folder nadal istnieje po deinstalatorze - usuń go ręcznie'
        'old.group'    = '  usunięto grupę menu Start tego profilu: {0}'
        'unins.slow'   = 'Deinstalator {0} nie skończył w ciągu {1} s'
        'install'      = 'Cicha instalacja do {0} (dla wszystkich) ...'
        'install.rc'   = 'Kod wyjścia instalatora {0} - zobacz {1}'
        'install.bad'  = 'Po instalacji brakuje {0} - zobacz {1}'
        'installed'    = 'Zainstalowano {0} -> {1}'
        'clean'        = 'Pozostałości per-user konta instalującego'
        'clean.item'   = '  usunięto: {0}'
        'clean.none'   = '  nie ma czego usuwać'
        'acl'          = 'Uprawnienia {0}: Użytkownicy odczyt + wykonanie, Administratorzy / SYSTEM pełne'
        'acl.rc'       = 'Kod wyjścia icacls {0} - uprawnienia {1} nie zostały zmienione'
        'acl.reset'    = '  {0} nadal jest zapisywalny dla użytkowników - przywracam dziedziczone uprawnienia plików w {1}'
        'acl.still'    = '  {0} nadal jest zapisywalny dla użytkowników - sprawdź uprawnienia {1}'
        'launch'       = 'Launchery i menu Start ({0})'
        'launch.item'  = '  {0} -> {1}'
        'launch.miss'  = '  {0}: brak {1} - pominięto'
        'path.add'     = 'PATH maszyny: dodano {0}'
        'path.same'    = 'PATH maszyny: foldery Demeter już są'
        'path.del'     = 'PATH maszyny: usunięto foldery Demeter'
        'assoc'        = 'Skojarzenie plików {0} -> {1}'
        'assoc.taken'  = 'Skojarzenie {0} pominięte: należy już do {1}'
        'smoke'        = 'Test: perl.exe ładuje Demeter'
        'smoke.ok'     = '  OK (Demeter {0}, prefiks Perla {1})'
        'smoke.bad'    = '  perl.exe -MDemeter nie działa (kod {0}): {1}'
        'smoke.reloc'  = '  Prefiks Perla to {0}, nie w {1} - relocation.pl.bat instalatora się nie wykonał (zobacz log instalatora)'
        'arp'          = 'Wpis odinstalowania: {0} {1}'
        'uninst'       = 'Usuwam {0}'
        'uninst.run'   = 'Deinstalator Demeter: {0}'
        'uninst.none'  = 'Nie ma czego usuwać'
        'done'         = 'Zakończono'
        'done.warn'    = 'Zakończono z ostrzeżeniami: {0}'
        'next'         = 'Dalej: zaloguj się na klonie testowym jako zwykły użytkownik (nie konto instalujące), uruchom Athena, Artemis i Hephaestus z menu Start, otwórz projekt, potem Seal + Push Image.'
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

function Get-VersionFromName {
    # Demeter_0.9.26_with_Strawberry_Perl_(64).exe -> 0.9.26
    param([string]$Name)
    if ($Name -match '^Demeter_(\d+(?:\.\d+)+)_') { return $Matches[1] }
    return ''
}

function Remove-PathSegment {
    # Returns $Value without the ;-separated entries that start with $Prefix (case-insensitive)
    param([string]$Value, [string]$Prefix)
    $keep = @($Value -split ';' | Where-Object { $_ -and -not $_.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) })
    return ($keep -join ';')
}

function Stop-DemeterProcess {
    param([string]$Folder = $Destination)
    $procs = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($Folder + '\', [StringComparison]::OrdinalIgnoreCase) })
    if ($procs.Count) { Write-Log (T 'running' $Folder $procs.Count) WARN; $procs | Stop-Process -Force }
}

function Invoke-InnoUninstall {
    # unins000.exe copies itself to %TEMP% and that copy does the work, so the started process may end before the
    # uninstall has finished: wait until unins000.exe (deleted as the last step) is gone
    param([string]$Folder, [int]$TimeoutSec = 900)
    $unins = Join-Path $Folder 'unins000.exe'
    $null = Start-Process -FilePath $unins -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait -PassThru
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Test-Path -LiteralPath $unins) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if (Test-Path -LiteralPath $unins) { Write-Log (T 'unins.slow' $Folder $TimeoutSec) WARN; return $false }
    return $true
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

# =====================================================================
#  CONFIGURATION
# =====================================================================
$Destination = $Destination.TrimEnd('\')
if (-not $Source) { $Source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Apps\Demeter' }   # PS 5.1: $PSScriptRoot is empty in param defaults
$ProductName = 'Demeter (Athena, Artemis, Hephaestus)'
$ArpKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VDI-ImageMaint-Demeter'
$InnoArpName = 'Strawberry_Perl_with_Demeter_is1'                  # AppId of the official installer + _is1
$InnoGroup   = 'Demeter with Strawberry Perl'                      # DefaultGroupName of the official installer
$InnoEnvKey  = 'HKCU:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'   # where the installer writes PATH / PGPLOT_DIR
$MenuDir     = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Demeter'
$VdiDir      = Join-Path $Destination 'vdi'
$SelfCopy    = Join-Path $VdiDir 'Install-Demeter.ps1'
$PerlExe     = Join-Path $Destination 'perl\bin\perl.exe'
$PathDirs    = @('perl\bin', 'perl\site\bin', 'c\bin') | ForEach-Object { Join-Path $Destination $_ }
$PgplotDir   = Join-Path $Destination 'c\lib\pgplot'
$Lib         = Join-Path $Destination 'perl\site\lib\Demeter\UI'

# Name -> launcher bat (perl\site\bin), arguments, icon, description (as in the official installer)
$Apps = @(
    @{ Name = 'Athena';            Bat = 'dathena.bat';     Args = '';     Icon = "$Lib\Athena\share\athena_icon.ico";   Desc = 'XAS Data Processing' }
    @{ Name = 'Artemis';           Bat = 'dartemis.bat';    Args = '';     Icon = "$Lib\Artemis\share\artemis_icon.ico"; Desc = 'EXAFS Data Analysis using Feff and Ifeffit' }
    @{ Name = 'Hephaestus';        Bat = 'dhephaestus.bat'; Args = '';     Icon = "$Lib\Hephaestus\icons\vulcan.ico";    Desc = 'A periodic table for the absorption spectroscopist' }
    @{ Name = 'Stand-alone Atoms'; Bat = 'datoms.bat';      Args = '--wx'; Icon = "$Lib\Atoms\icons\atoms.ico";          Desc = 'Crystallography for the absorption spectroscopist' }
)
# extension -> ProgID, launcher, description
$Assocs = @(
    @{ Ext = '.prj'; ProgId = 'Demeter.Athena.Project';  App = 'Athena';  Desc = 'Athena project file' }
    @{ Ext = '.fpj'; ProgId = 'Demeter.Artemis.Project'; App = 'Artemis'; Desc = 'Artemis fitting project' }
)

# =====================================================================
#  START
# =====================================================================
$log = Join-Path $LogDir "Demeter_$Stamp.log"
Start-Transcript -Path $log -Force -WhatIf:$false -Confirm:$false | Out-Null
try {
    Write-Log (T 'hdr' $env:COMPUTERNAME ([Security.Principal.WindowsIdentity]::GetCurrent().Name)) STEP
    if ($Destination -match '\s') { throw (T 'dest.space' $Destination) }

    # ---------- uninstall ----------
    if ($Uninstall) {
        Stop-DemeterProcess
        $unins = Join-Path $Destination 'unins000.exe'
        if ((Test-Path $unins) -and $PSCmdlet.ShouldProcess($unins, (T 'uninst.run' $unins))) {
            Write-Log (T 'uninst.run' $unins)
            $null = Invoke-InnoUninstall $Destination
        }
        $items = @($Destination, $MenuDir, $ArpKey) + @($Assocs | ForEach-Object { "HKLM:\SOFTWARE\Classes\$($_.ProgId)" })
        $items = @($items | Where-Object { Test-Path $_ })
        foreach ($a in $Assocs) {
            $k = "HKLM:\SOFTWARE\Classes\$($a.Ext)"
            if ((Get-RegValue $k '') -eq $a.ProgId) { $items += $k }
        }
        if (-not $items.Count) { Write-Log (T 'uninst.none') OK }
        foreach ($it in $items) {
            if ($PSCmdlet.ShouldProcess($it, (T 'uninst' $it))) { Remove-Item -LiteralPath $it -Recurse -Force; Write-Log (T 'uninst' $it) OK }
        }
        $envKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        $mp = [string](Get-RegValue $envKey 'Path')
        $np = Remove-PathSegment $mp ($Destination + '\')
        if ($np -ne $mp -and $PSCmdlet.ShouldProcess('PATH', (T 'path.del'))) {
            [Environment]::SetEnvironmentVariable('Path', $np, 'Machine'); Write-Log (T 'path.del') OK
        }
        if ([string](Get-RegValue $envKey 'PGPLOT_DIR') -eq $PgplotDir -and $PSCmdlet.ShouldProcess('PGPLOT_DIR', 'remove')) {
            [Environment]::SetEnvironmentVariable('PGPLOT_DIR', $null, 'Machine')
        }
    } else {

    # ---------- 1. installer ----------
    $exe = $null
    if (Test-Path $Source -PathType Leaf) { $exe = Get-Item $Source }
    elseif (Test-Path $Source) {
        $exe = Get-ChildItem -Path $Source -File -Filter 'Demeter_*_with_Strawberry_Perl_(64)*.exe' |
            Where-Object { Get-VersionFromName $_.Name } |
            Sort-Object @{ Expression = { [version](Get-VersionFromName $_.Name) }; Descending = $true } | Select-Object -First 1
    }
    if (-not $exe) { throw (T 'exe.none' $Source) }
    $version = Get-VersionFromName $exe.Name
    if (-not $version -and [string]$exe.VersionInfo.ProductVersion -match '\d+(\.\d+)+') { $version = $Matches[0] }   # renamed file
    if (-not $version) { throw (T 'exe.nover' $exe.FullName) }
    Write-Log (T 'exe.found' $exe.FullName $version)

    $installed = [string](Get-RegValue $ArpKey 'DisplayVersion')
    Write-Log (T 'state' $(if ($installed) { $installed } else { T 'state.none' }) $version $Destination)

    # ---------- 0. earlier per-user copies (any local profile, or the Uninstall entry of this account) ----------
    $old = @()
    foreach ($root in 'HKCU:', 'HKLM:') {
        $prev = ([string](Get-RegValue "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$InnoArpName" 'InstallLocation')).TrimEnd('\')
        if ($prev) { $old += $prev }
    }
    $profiles = @(Get-ProfileFolder)
    foreach ($p in $profiles) { $old += Join-Path $p 'AppData\Roaming\DemeterPerl' }
    $old = @($old | Where-Object { $_ -ne $Destination -and (Test-Path -LiteralPath (Join-Path $_ 'unins000.exe')) } | Sort-Object -Unique)
    foreach ($o in $old) {
        if (-not $PSCmdlet.ShouldProcess($o, (T 'old' $o))) { continue }
        Write-Log (T 'old' $o) WARN
        Stop-DemeterProcess -Folder $o
        $null = Invoke-InnoUninstall $o
        if (Test-Path -LiteralPath (Join-Path $o 'perl\bin\perl.exe')) { Write-Log (T 'old.left' $o) WARN }
        # the uninstaller ran as this account: the Start menu group of the profile that owns the copy stays
        foreach ($p in $profiles) {
            if (-not $o.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $grp = Join-Path $p "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\$InnoGroup"
            if (Test-Path -LiteralPath $grp) { Remove-Item -LiteralPath $grp -Recurse -Force; Write-Log (T 'old.group' $grp) }
        }
    }

    if ($installed -eq $version -and (Test-Path $PerlExe)) {
        Write-Log (T 'current' $version) OK
    } elseif ($PSCmdlet.ShouldProcess($Destination, "$($exe.Name) -> $Destination")) {
        Stop-DemeterProcess
        $setupLog = Join-Path $LogDir "DemeterSetup_$Stamp.log"
        Unblock-File -LiteralPath $exe.FullName   # no "Open File - Security Warning" for a downloaded installer
        Write-Log (T 'install' $Destination)
        # /TASKS="" = no desktop icons. The [Run] entry relocation.pl.bat has no postinstall flag, so it runs in
        # silent mode too (rewrites Perl paths to /DIR). An existing install with the same AppId (also ours in
        # $Destination) is uninstalled by the installer's own code before the files are copied.
        $al = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /TASKS="" /DIR="{0}" /LOG="{1}"' -f $Destination, $setupLog
        $rc = (Start-Process -FilePath $exe.FullName -ArgumentList $al -Wait -PassThru).ExitCode
        if ($rc -ne 0) { throw (T 'install.rc' $rc $setupLog) }
        foreach ($f in @($PerlExe, (Join-Path $Destination 'perl\site\bin\dathena.bat'))) {
            if (-not (Test-Path $f)) { throw (T 'install.bad' $f $setupLog) }
        }
        Write-Log (T 'installed' $exe.Name $Destination) OK
    }

    # -WhatIf before the first install: nothing to configure yet
    if (Test-Path $PerlExe) {

    # ---------- 2. per-user leftovers of the installing account ----------
    Write-Log (T 'clean') STEP
    $removed = 0
    # PATH / PGPLOT_DIR: the installer writes them to HKCU\SYSTEM\...\Environment (never read by Windows);
    # HKCU\Environment is checked as well (other installer builds)
    foreach ($ek in @($InnoEnvKey, 'HKCU:\Environment')) {
        $up = [string](Get-RegValue $ek 'Path')
        $nup = Remove-PathSegment $up ($Destination + '\')
        if ($up -and $up -ne $nup -and $PSCmdlet.ShouldProcess("$ek Path", 'remove Demeter folders')) {
            if ($nup) { Set-ItemProperty -LiteralPath $ek -Name 'Path' -Value $nup } else { Remove-ItemProperty -LiteralPath $ek -Name 'Path' }
            $removed++; Write-Log (T 'clean.item' "$ek Path")
        }
        if ([string](Get-RegValue $ek 'PGPLOT_DIR') -like "$Destination\*" -and $PSCmdlet.ShouldProcess("$ek PGPLOT_DIR", 'remove')) {
            Remove-ItemProperty -LiteralPath $ek -Name 'PGPLOT_DIR'; $removed++; Write-Log (T 'clean.item' "$ek PGPLOT_DIR")
        }
    }
    # the installer created HKCU\SYSTEM\CurrentControlSet\... only for these values: remove the chain when empty
    $k = $InnoEnvKey
    while ($k -match '^HKCU:\\SYSTEM' -and (Test-Path -LiteralPath $k)) {
        $item = Get-Item -LiteralPath $k
        if ($item.SubKeyCount -or $item.ValueCount -or -not $PSCmdlet.ShouldProcess($k, 'remove empty key')) { break }
        Remove-Item -LiteralPath $k -Force; $removed++; Write-Log (T 'clean.item' $k)
        $k = Split-Path $k -Parent
    }
    # The official installer writes these to the HKCU root (not Software\Classes) - they never worked
    $junk = @('HKCU:\.pl', 'HKCU:\Perl', 'HKCU:\.prj', 'HKCU:\Athena', 'HKCU:\.fpj', 'HKCU:\Artemis')
    $junk += Join-Path ([Environment]::GetFolderPath('Programs')) $InnoGroup
    $junk += Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$InnoGroup"
    foreach ($d in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'))) {
        foreach ($n in 'Athena', 'Artemis', 'Hephaestus') {
            $lnkPath = Join-Path $d "$n.lnk"
            if (Test-Path $lnkPath) {
                $t = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath).TargetPath
                if ($t -like "$Destination\*") { $junk += $lnkPath }
            }
        }
    }
    foreach ($j in $junk) {
        if ((Test-Path $j) -and $PSCmdlet.ShouldProcess($j, 'remove')) { Remove-Item -LiteralPath $j -Recurse -Force; $removed++; Write-Log (T 'clean.item' $j) }
    }
    # The installer's own Uninstall entry (HKLM or HKCU, depends on the Inno Setup version): hidden, ours is the visible one
    foreach ($root in 'HKLM:', 'HKCU:') {
        $k = "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$InnoArpName"
        if ((Test-Path $k) -and (Get-RegValue $k 'SystemComponent') -ne 1 -and $PSCmdlet.ShouldProcess($k, 'SystemComponent=1')) {
            New-ItemProperty -Path $k -Name 'SystemComponent' -Value 1 -PropertyType DWord -Force | Out-Null; $removed++; Write-Log (T 'clean.item' "$k (SystemComponent=1)")
        }
    }
    if (-not $removed) { Write-Log (T 'clean.none') }

    # ---------- 3. permissions ----------
    Write-Log (T 'acl' $Destination) STEP
    if ($PSCmdlet.ShouldProcess($Destination, 'icacls')) {
        # SIDs: SYSTEM, Administrators, Users (language-neutral). Inheritable ACEs propagate to the existing files.
        $ic = Invoke-Icacls @($Destination, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/Q')
        if ($ic.Rc -ne 0) { Write-Log (T 'acl.rc' $ic.Rc $Destination) WARN; Write-Log $ic.Text }
        else {
            # files with their own (non-inherited) ACL keep it: verify a sample, reset the tree when needed
            $sample = @($PerlExe, (Join-Path $Destination 'perl\site\bin\dathena.bat')) | Where-Object { Test-UserWritable $_ } | Select-Object -First 1
            if ($sample) {
                Write-Log (T 'acl.reset' $sample $Destination) WARN
                $ic = Invoke-Icacls @((Join-Path $Destination '*'), '/reset', '/T', '/C', '/Q')
                if ($ic.Rc -ne 0 -or (Test-UserWritable $sample)) { Write-Log (T 'acl.still' $sample $Destination) WARN; Write-Log $ic.Text }
            }
        }
    }

    # ---------- 4. launchers, Start menu, PATH, associations ----------
    Write-Log (T 'launch' $MenuDir) STEP
    if ($PSCmdlet.ShouldProcess($VdiDir, 'launchers + shortcuts')) {
        New-Item -ItemType Directory -Path $VdiDir, $MenuDir -Force | Out-Null
        # the Uninstall entry runs this copy (C:\install may be gone by then)
        if ($PSCommandPath -and $PSCommandPath -ne $SelfCopy) { Copy-Item -LiteralPath $PSCommandPath -Destination $SelfCopy -Force }
        $sh = New-Object -ComObject WScript.Shell
        foreach ($a in $Apps) {
            $bat = Join-Path $Destination "perl\site\bin\$($a.Bat)"
            if (-not (Test-Path $bat)) { Write-Log (T 'launch.miss' $a.Name $bat) WARN; continue }
            $cmd = Join-Path $VdiDir ($a.Name.Replace(' ', '-') + '.cmd')
            $callLine = ('call "{0}" {1}' -f $bat, $a.Args).TrimEnd() + ' %*'
            $text = @(
                '@echo off'
                'rem VDI-ImageMaint Install-Demeter.ps1 - all-users launcher: environment of the official per-user installer, per process'
                'setlocal'
                ('set "PATH={0};%PATH%"' -f ($PathDirs -join ';'))
                ('set "PGPLOT_DIR={0}"' -f $PgplotDir)
                'if not exist "%APPDATA%\demeter" mkdir "%APPDATA%\demeter"'
                ('cd /d "{0}"' -f $Destination)
                $callLine
            )
            [IO.File]::WriteAllText($cmd, (($text -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
            $lnk = $sh.CreateShortcut((Join-Path $MenuDir "$($a.Name).lnk"))
            $lnk.TargetPath = $cmd
            $lnk.WorkingDirectory = $Destination
            $lnk.WindowStyle = 7   # minimized: the console of the Perl launcher stays out of the way
            if (Test-Path $a.Icon) { $lnk.IconLocation = "$($a.Icon),0" }
            $lnk.Description = $a.Desc
            $lnk.Save()
            Write-Log (T 'launch.item' $a.Name $cmd)
        }
    }

    $envKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $mp = [string](Get-RegValue $envKey 'Path')
    if ($AddToPath) {
        $missing = @($PathDirs | Where-Object { ($mp -split ';') -notcontains $_ })
        if (-not $missing.Count) { Write-Log (T 'path.same') }
        elseif ($PSCmdlet.ShouldProcess('PATH', ($missing -join ';'))) {
            [Environment]::SetEnvironmentVariable('Path', ($mp.TrimEnd(';') + ';' + ($missing -join ';')), 'Machine')
            Write-Log (T 'path.add' ($missing -join ';')) OK
        }
        if ([string](Get-RegValue $envKey 'PGPLOT_DIR') -ne $PgplotDir -and $PSCmdlet.ShouldProcess('PGPLOT_DIR', $PgplotDir)) {
            [Environment]::SetEnvironmentVariable('PGPLOT_DIR', $PgplotDir, 'Machine')
        }
    } else {
        $np = Remove-PathSegment $mp ($Destination + '\')
        if ($np -ne $mp -and $PSCmdlet.ShouldProcess('PATH', (T 'path.del'))) {
            [Environment]::SetEnvironmentVariable('Path', $np, 'Machine'); Write-Log (T 'path.del') OK
        }
    }

    if ($Associate) {
        foreach ($a in $Assocs) {
            $extKey = "HKLM:\SOFTWARE\Classes\$($a.Ext)"
            $owner = [string](Get-RegValue $extKey '')
            if ($owner -and $owner -ne $a.ProgId) { Write-Log (T 'assoc.taken' $a.Ext $owner) WARN; continue }
            $app = @($Apps | Where-Object { $_.Name -eq $a.App })[0]
            $cmd = Join-Path $VdiDir "$($a.App).cmd"
            if ($PSCmdlet.ShouldProcess($extKey, $a.ProgId)) {
                $pk = "HKLM:\SOFTWARE\Classes\$($a.ProgId)"
                New-Item -Path "$pk\shell\open\command" -Force | Out-Null
                New-Item -Path "$pk\DefaultIcon" -Force | Out-Null
                New-Item -Path $extKey -Force | Out-Null
                Set-Item -Path $extKey -Value $a.ProgId
                Set-Item -Path $pk -Value $a.Desc
                Set-Item -Path "$pk\DefaultIcon" -Value "$($app.Icon),0"
                Set-Item -Path "$pk\shell\open\command" -Value ('"{0}" "%1"' -f $cmd)
                Write-Log (T 'assoc' $a.Ext $a.App) OK
            }
        }
    }

    # ---------- 5. smoke test ----------
    Write-Log (T 'smoke') STEP
    $savedPath = $env:Path; $savedPg = $env:PGPLOT_DIR
    try {
        $env:Path = ($PathDirs -join ';') + ';' + $env:Path
        $env:PGPLOT_DIR = $PgplotDir
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        # no double quotes inside the argument (PS 5.1 passes them to native programs unescaped)
        $out = & $PerlExe -MConfig -MDemeter -e 'print $Demeter::VERSION, q{|}, $Config{prefix}' 2>&1
        $pRc = $LASTEXITCODE
        $ErrorActionPreference = $eap
        $text = (($out | ForEach-Object { [string]$_ }) -join ' ').Trim()
        # stdout only (Perl warnings on stderr must not end up in the version / prefix)
        $std = (@($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join '').Trim()
        if ($pRc -ne 0) { Write-Log (T 'smoke.bad' $pRc $text) WARN }
        else {
            $parts = $std.Split('|')
            $ver = $parts[0].Trim(); $prefix = $(if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' })
            if ($prefix.Replace('/', '\').StartsWith($Destination + '\', [StringComparison]::OrdinalIgnoreCase)) { Write-Log (T 'smoke.ok' $ver $prefix) OK }
            else { Write-Log (T 'smoke.reloc' $prefix $Destination) WARN }
        }
    } finally {
        $env:Path = $savedPath; $env:PGPLOT_DIR = $savedPg
    }

    # ---------- 6. Uninstall entry ----------
    if ($PSCmdlet.ShouldProcess($ArpKey, "DisplayVersion=$version")) {
        if (-not (Test-Path $ArpKey)) { New-Item -Path $ArpKey -Force | Out-Null }
        $uninst = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Destination "{1}" -Uninstall' -f $SelfCopy, $Destination
        $vals = [ordered]@{
            DisplayName = $ProductName; DisplayVersion = $version; Publisher = 'Bruce Ravel'
            InstallLocation = $Destination; DisplayIcon = $Apps[0].Icon; Comments = 'Demeter with Strawberry Perl, all users (VDI-ImageMaint)'
            UninstallString = $uninst; QuietUninstallString = $uninst; URLInfoAbout = 'https://bruceravel.github.io/demeter/'
        }
        foreach ($k in $vals.Keys) { New-ItemProperty -Path $ArpKey -Name $k -Value ([string]$vals[$k]) -PropertyType String -Force | Out-Null }
        foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty -Path $ArpKey -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
        Write-Log (T 'arp' $ProductName $version) OK
    }
    Write-Log (T 'next')
    }   # Test-Path $PerlExe
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
