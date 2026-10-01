#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs an Eclipse IDE package (EPP ZIP) per machine on a Windows 11 VDI golden image (Horizon Instant Clone).

.DESCRIPTION
    Eclipse has no installer: the EPP ZIP is extracted to a fixed folder (default %ProgramFiles%\Eclipse\<Package>)
    and configured for non-persistent desktops with the profile in an FSLogix container:

    1. Install / update: the newest eclipse-<Package>-<YYYY-MM>-R-win32-x86_64.zip from -Source replaces the
       installed release (signature of eclipse.exe checked). The folder stays read-only for users, so Eclipse
       works as a shared install: per-user configuration goes to %USERPROFILE%\.eclipse (in the container).
    2. eclipse.ini: default workspace (@user.home = %USERPROFILE% = FSLogix container), optional -data (no
       workspace prompt), optional -Xmx, optional -vm, -Declipse.pluginCustomization.
    3. plugin_customization.ini: automatic update checks off (the image is updated by VDI-ImageMaint), Oomph
       startup tasks off, JDK detection at startup on (Temurin in %ProgramFiles%\Eclipse Adoptium is found
       automatically and offered under Installed JREs / execution environments).
    4. Start menu shortcut for all users and an Uninstall entry (DisplayVersion = release, e.g. 2026.09) -
       detection for the VDI-ImageMaint manifest (Detect Uninstall + VersionFile).

    Idempotent: when the release is already installed only the configuration is re-applied.
    Supports -WhatIf.

.PARAMETER Source
    Folder with the EPP ZIP(s) or the path of one ZIP. Default: <C:\install>\Apps\Eclipse.
.PARAMETER Package
    EPP package: java (Eclipse IDE for Java Developers) or jee (Enterprise Java and Web Developers).
.PARAMETER Destination
    Install folder. Default %ProgramFiles%\Eclipse\<Package>. Keep it fixed - shortcuts, DEM and AV rules use it.
.PARAMETER Workspace
    Default workspace. Default @user.home/eclipse-workspace (inside the FSLogix profile container).
    Do not point it at a UNC path / redirected folder: workspace metadata over SMB is slow and its .lock breaks.
.PARAMETER ForceWorkspace
    Writes -data to eclipse.ini: Eclipse opens -Workspace without asking (student labs).
.PARAMETER MaxHeapMB
    -Xmx for the IDE (0 = keep the eclipse.ini value / JVM default).
.PARAMETER Vm
    JDK folder that runs the IDE ('' = the JustJ JRE bundled with the package - recommended, it always matches
    osgi.requiredJavaVersion). It does not limit which JDKs projects compile against.
.PARAMETER AllowUserUpdates
    Keeps the automatic update check of the package (not recommended on Instant Clones).
.PARAMETER Uninstall
    Removes the install folder, the shortcut and the Uninstall entry.
.PARAMETER Language
    auto (UI culture: pl -> Polish, everything else -> English), en, pl.

.EXAMPLE
    .\Install-Eclipse.ps1 -WhatIf
.EXAMPLE
    .\Install-Eclipse.ps1 -Source C:\install\Apps\Eclipse -ForceWorkspace -MaxHeapMB 3072

.NOTES
    Version 1.0. Log: C:\ProgramData\VDI-ImageMaint\Logs\Eclipse_<date>.log
    JDKs: Temurin MSI packages TemurinJDK21 / TemurinJDK25 in packages.json (fixed INSTALLDIR).
    Design and DEM folder redirection: docs/eclipse-java.md.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Source = '',
    [ValidateSet('java', 'jee')]
    [string]$Package = 'java',
    [string]$Destination = '',
    [string]$Workspace = '@user.home/eclipse-workspace',
    [switch]$ForceWorkspace,
    [ValidateRange(0, 32768)]
    [int]$MaxHeapMB = 0,
    [string]$Vm = '',
    [switch]$AllowUserUpdates,
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
        'hdr'           = 'Eclipse IDE ({0}) - VDI install | {1} | {2}'
        'zip.none'      = 'No eclipse-{0}-*-win32-x86_64.zip in {1} (download it: docs/downloads.md or -Mode Download)'
        'zip.found'     = 'Package: {0} (release {1})'
        'state'         = 'Installed: {0} | package: {1} | folder: {2}'
        'state.none'    = 'none'
        'current'       = 'Release {0} already installed - re-applying the configuration only'
        'running'       = 'Eclipse is running from {0} - stopping {1} process(es)'
        'extract'       = 'Extracting {0} ...'
        'extract.bad'   = 'The archive has no eclipse\eclipse.exe - not an EPP package for Windows'
        'sig.bad'       = 'eclipse.exe signature: {0} ({1}) - expected the Eclipse Foundation; nothing was changed'
        'sig.ok'        = 'eclipse.exe signed by: {0}'
        'replace'       = 'Replacing {0}'
        'installed'     = 'Installed {0} -> {1}'
        'ini'           = 'eclipse.ini'
        'ini.set'       = '  {0}'
        'ini.same'      = '  eclipse.ini unchanged'
        'ini.saved'     = '  eclipse.ini saved ({0} change(s), original: eclipse.ini.orig)'
        'vm.missing'    = '  -Vm {0}: bin\javaw.exe not found - keeping the bundled JRE'
        'vm.old'        = '  -Vm {0}: Java {1} is older than osgi.requiredJavaVersion={2} - keeping the bundled JRE'
        'vm.bundled'    = '  -vm: bundled JustJ JRE (Java {0})'
        'cust'          = 'plugin_customization.ini'
        'cust.same'     = '  unchanged ({0} preferences)'
        'cust.saved'    = '  saved {0} preferences: {1}'
        'updates.off'   = '  automatic update check: off (the image is updated by VDI-ImageMaint)'
        'updates.on'    = '  automatic update check: kept (-AllowUserUpdates)'
        'jdks'          = 'JDKs detected by Eclipse at startup (%ProgramFiles%\Eclipse Adoptium): {0}'
        'jdks.none'     = 'No JDK in %ProgramFiles%\Eclipse Adoptium - install TemurinJDK21 / TemurinJDK25 (packages.json), otherwise projects build against the bundled JRE only'
        'shortcut'      = 'Start menu shortcut: {0}'
        'arp'           = 'Uninstall entry: {0} {1}'
        'ws'            = 'Workspace: {0} ({1})'
        'ws.forced'     = 'no prompt, -data'
        'ws.prompt'     = 'default in the prompt'
        'ws.unc'        = 'Workspace {0} is a UNC path / redirected folder - Eclipse metadata over SMB is slow and the .lock breaks. Use the FSLogix container (@user.home/...)'
        'uninst'        = 'Removing {0}'
        'uninst.none'   = 'Nothing to remove'
        'done'          = 'Done'
        'done.warn'     = 'Done with {0} warning(s)'
        'next'          = 'Next: log on to a test clone (FSLogix container + DEM folder redirection), open Eclipse and check Window > Preferences > Java > Installed JREs, then Seal + Push Image.'
    }
    pl = @{
        'hdr'           = 'Eclipse IDE ({0}) - instalacja VDI | {1} | {2}'
        'zip.none'      = 'Brak eclipse-{0}-*-win32-x86_64.zip w {1} (pobierz: docs/pl/downloads.md albo -Mode Download)'
        'zip.found'     = 'Pakiet: {0} (wydanie {1})'
        'state'         = 'Zainstalowane: {0} | pakiet: {1} | folder: {2}'
        'state.none'    = 'brak'
        'current'       = 'Wydanie {0} jest już zainstalowane - tylko ponowne zastosowanie konfiguracji'
        'running'       = 'Eclipse działa z {0} - zatrzymuję procesy: {1}'
        'extract'       = 'Rozpakowywanie {0} ...'
        'extract.bad'   = 'Archiwum nie zawiera eclipse\eclipse.exe - to nie jest pakiet EPP dla Windows'
        'sig.bad'       = 'Podpis eclipse.exe: {0} ({1}) - oczekiwano Eclipse Foundation; nic nie zmieniono'
        'sig.ok'        = 'eclipse.exe podpisany przez: {0}'
        'replace'       = 'Zastępuję {0}'
        'installed'     = 'Zainstalowano {0} -> {1}'
        'ini'           = 'eclipse.ini'
        'ini.set'       = '  {0}'
        'ini.same'      = '  eclipse.ini bez zmian'
        'ini.saved'     = '  zapisano eclipse.ini (zmian: {0}, oryginał: eclipse.ini.orig)'
        'vm.missing'    = '  -Vm {0}: brak bin\javaw.exe - zostaje dołączone JRE'
        'vm.old'        = '  -Vm {0}: Java {1} jest starsza niż osgi.requiredJavaVersion={2} - zostaje dołączone JRE'
        'vm.bundled'    = '  -vm: dołączone JRE JustJ (Java {0})'
        'cust'          = 'plugin_customization.ini'
        'cust.same'     = '  bez zmian (preferencji: {0})'
        'cust.saved'    = '  zapisano preferencji: {0}: {1}'
        'updates.off'   = '  automatyczne sprawdzanie aktualizacji: wyłączone (obraz aktualizuje VDI-ImageMaint)'
        'updates.on'    = '  automatyczne sprawdzanie aktualizacji: pozostawione (-AllowUserUpdates)'
        'jdks'          = 'JDK wykrywane przez Eclipse przy starcie (%ProgramFiles%\Eclipse Adoptium): {0}'
        'jdks.none'     = 'Brak JDK w %ProgramFiles%\Eclipse Adoptium - zainstaluj TemurinJDK21 / TemurinJDK25 (packages.json), inaczej projekty budują się tylko na dołączonym JRE'
        'shortcut'      = 'Skrót w menu Start: {0}'
        'arp'           = 'Wpis odinstalowania: {0} {1}'
        'ws'            = 'Workspace: {0} ({1})'
        'ws.forced'     = 'bez pytania, -data'
        'ws.prompt'     = 'domyślny w oknie wyboru'
        'ws.unc'        = 'Workspace {0} to ścieżka UNC / przekierowany folder - metadane Eclipse przez SMB są wolne, a .lock się psuje. Użyj kontenera FSLogix (@user.home/...)'
        'uninst'        = 'Usuwam {0}'
        'uninst.none'   = 'Nie ma czego usuwać'
        'done'          = 'Zakończono'
        'done.warn'     = 'Zakończono z ostrzeżeniami: {0}'
        'next'          = 'Dalej: logowanie na klonie testowym (kontener FSLogix + przekierowanie folderów DEM), Eclipse > Window > Preferences > Java > Installed JREs, potem Seal + Push Image.'
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
    # eclipse-java-2026-09-R-win32-x86_64.zip -> 2026.09 (release train = version used for detection)
    param([string]$Name)
    if ($Name -match '-(\d{4})-(\d{2})-') { return "$($Matches[1]).$($Matches[2])" }
    return ''
}

function Get-JavaMajor {
    # <jdk>\release: JAVA_VERSION="21.0.12" -> 21
    param([string]$JdkDir)
    $rel = Join-Path $JdkDir 'release'
    if (-not (Test-Path $rel)) { return 0 }
    $m = Select-String -Path $rel -Pattern '^JAVA_VERSION="(\d+)' | Select-Object -First 1
    if ($m) { return [int]$m.Matches[0].Groups[1].Value }
    return 0
}

function Edit-IniValue {
    # Replaces the line starting with $Prefix (or appends it to the section) - returns the new line list
    param([System.Collections.Generic.List[string]]$Lines, [int]$Start, [int]$End, [string]$Prefix, [string]$Line)
    for ($i = $Start; $i -lt $End; $i++) {
        if ($Lines[$i].StartsWith($Prefix)) {
            if ($Lines[$i] -ceq $Line) { return $false }
            $Lines[$i] = $Line; return $true
        }
    }
    $Lines.Insert($End, $Line)
    return $true
}

function Clear-IniPair {
    # Removes an option + value pair (e.g. -data / path) from the launcher part; returns $true when removed
    param([System.Collections.Generic.List[string]]$Lines, [string]$Option)
    $i = $Lines.IndexOf($Option)
    $vmargs = $Lines.IndexOf('-vmargs')
    if ($i -lt 0 -or ($vmargs -ge 0 -and $i -gt $vmargs)) { return $false }
    $Lines.RemoveAt($i)
    if ($i -lt $Lines.Count) { $Lines.RemoveAt($i) }
    return $true
}

function Edit-IniPair {
    # Sets an option + value pair (e.g. -vm / path) in the launcher part (before -vmargs)
    param([System.Collections.Generic.List[string]]$Lines, [string]$Option, [string]$Value)
    $i = $Lines.IndexOf($Option)
    $vmargs = $Lines.IndexOf('-vmargs')
    if ($i -ge 0 -and ($vmargs -lt 0 -or $i -lt $vmargs) -and $i + 1 -lt $Lines.Count) {
        if ($Lines[$i + 1] -ceq $Value) { return $false }
        $Lines[$i + 1] = $Value; return $true
    }
    if ($vmargs -lt 0) { $vmargs = $Lines.Count }
    $Lines.Insert($vmargs, $Value); $Lines.Insert($vmargs, $Option)
    return $true
}

function Write-TextFile {
    # Eclipse reads eclipse.ini / plugin_customization.ini without BOM handling: UTF-8 without BOM, CRLF
    param([string]$Path, [string[]]$Lines)
    [IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# =====================================================================
#  CONFIGURATION
# =====================================================================
$Products = @{
    java = 'Eclipse IDE for Java Developers'
    jee  = 'Eclipse IDE for Enterprise Java and Web Developers'
}
$ProductName = $Products[$Package]
if (-not $Destination) { $Destination = Join-Path $env:ProgramFiles "Eclipse\$Package" }
if (-not $Source) { $Source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Apps\Eclipse' }   # PS 5.1: $PSScriptRoot is empty in param defaults
$ArpKey      = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VDI-ImageMaint-Eclipse-$Package"
$Shortcut    = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$ProductName.lnk"
$AdoptiumDir = Join-Path $env:ProgramFiles 'Eclipse Adoptium'
$SignerRx    = 'Eclipse'

# Preferences for non-persistent VDI (keys verified in the 2026-09 plug-ins)
$Customization = [ordered]@{
    'org.eclipse.oomph.setup.ui/skip.startup.tasks'          = 'true'    # no Oomph setup tasks at every logon
    'org.eclipse.oomph.setup.ui/enable.preference.recorder'  = 'false'
    'org.eclipse.jdt.launching/detectVMsAtStartup'           = 'true'    # finds the Temurin JDKs in %ProgramFiles%\Eclipse Adoptium
    'org.eclipse.m2e.core/eclipse.m2.updateIndexes'          = 'false'   # no Maven Central index in the container
}
if (-not $AllowUserUpdates) {
    $Customization['org.eclipse.equinox.p2.ui.sdk.scheduler/enabled']  = 'false'
    $Customization['org.eclipse.equinox.p2.ui.sdk.scheduler/download'] = 'false'
}

# =====================================================================
#  START
# =====================================================================
$log = Join-Path $LogDir "Eclipse_$Stamp.log"
Start-Transcript -Path $log -Force -WhatIf:$false -Confirm:$false | Out-Null
try {
    Write-Log (T 'hdr' $Package $env:COMPUTERNAME ([Security.Principal.WindowsIdentity]::GetCurrent().Name)) STEP

    # ---------- uninstall ----------
    if ($Uninstall) {
        $items = @($Destination, $Shortcut, $ArpKey) | Where-Object { Test-Path $_ }
        if (-not $items) { Write-Log (T 'uninst.none') OK }
        foreach ($it in $items) {
            if ($PSCmdlet.ShouldProcess($it, (T 'uninst' $it))) { Remove-Item -LiteralPath $it -Recurse -Force; Write-Log (T 'uninst' $it) OK }
        }
    } else {

    # ---------- 1. package ----------
    $zip = $null
    if (Test-Path $Source -PathType Leaf) { $zip = Get-Item $Source }
    elseif (Test-Path $Source) {
        $zip = Get-ChildItem -Path $Source -File -Filter "eclipse-$Package-*-win32-x86_64.zip" |
            Sort-Object @{ Expression = { Get-ReleaseFromName $_.Name }; Descending = $true } | Select-Object -First 1
    }
    if (-not $zip) { throw (T 'zip.none' $Package $Source) }
    $release = Get-ReleaseFromName $zip.Name
    Write-Log (T 'zip.found' $zip.FullName $release)

    $installed = [string](Get-RegValue $ArpKey 'DisplayVersion')
    $exe = Join-Path $Destination 'eclipse.exe'
    Write-Log (T 'state' $(if ($installed) { $installed } else { T 'state.none' }) $release $Destination)

    if ($installed -eq $release -and (Test-Path $exe)) {
        Write-Log (T 'current' $release) OK
    } elseif ($PSCmdlet.ShouldProcess($Destination, "$($zip.Name) -> $Destination")) {
        $tmp = Join-Path $env:ProgramData "VDI-ImageMaint\tmp-eclipse-$Stamp"   # short path: plug-in paths are long
        try {
            Write-Log (T 'extract' $zip.Name)
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName, $tmp)
            $newExe = Join-Path $tmp 'eclipse\eclipse.exe'
            if (-not (Test-Path $newExe)) { throw (T 'extract.bad') }
            $sig = Get-AuthenticodeSignature -FilePath $newExe
            $subject = $(if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' })
            if ($sig.Status -ne 'Valid' -or $subject -notmatch $SignerRx) { throw (T 'sig.bad' $sig.Status $subject) }
            Write-Log (T 'sig.ok' $subject) OK

            $procs = @(Get-Process -Name eclipse, eclipsec, javaw -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -and $_.Path.StartsWith($Destination, [StringComparison]::OrdinalIgnoreCase) })
            if ($procs.Count) { Write-Log (T 'running' $Destination $procs.Count) WARN; $procs | Stop-Process -Force }
            if (Test-Path $Destination) { Write-Log (T 'replace' $Destination); Remove-Item -LiteralPath $Destination -Recurse -Force }
            $parent = Split-Path $Destination -Parent
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Move-Item -LiteralPath (Join-Path $tmp 'eclipse') -Destination $Destination
            Copy-Item (Join-Path $Destination 'eclipse.ini') (Join-Path $Destination 'eclipse.ini.orig') -Force
            Write-Log (T 'installed' $zip.Name $Destination) OK
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # -WhatIf before the first install: nothing to configure yet
    if (Test-Path $exe) {

    # ---------- 2. eclipse.ini ----------
    Write-Log (T 'ini') STEP
    $iniPath = Join-Path $Destination 'eclipse.ini'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in [IO.File]::ReadAllLines($iniPath)) { if ($l.Trim()) { $lines.Add($l.Trim()) } }
    $changes = 0

    $required = 0
    $rq = @($lines | Where-Object { $_ -match '^-Dosgi\.requiredJavaVersion=(\d+)' })
    if ($rq.Count -and $rq[0] -match '=(\d+)') { $required = [int]$Matches[1] }
    if ($Vm) {
        $major = Get-JavaMajor $Vm
        if (-not (Test-Path (Join-Path $Vm 'bin\javaw.exe'))) { Write-Log (T 'vm.missing' $Vm) WARN }
        elseif ($required -and $major -lt $required) { Write-Log (T 'vm.old' $Vm $major $required) WARN }
        elseif (Edit-IniPair $lines '-vm' (Join-Path $Vm 'bin')) { $changes++; Write-Log (T 'ini.set' "-vm $(Join-Path $Vm 'bin')") }
    } else {
        Write-Log (T 'vm.bundled' $required)
    }

    if ($Workspace -match '^\\\\') { Write-Log (T 'ws.unc' $Workspace) WARN }
    if ($ForceWorkspace) {
        if (Edit-IniPair $lines '-data' $Workspace) { $changes++; Write-Log (T 'ini.set' "-data $Workspace") }
    } elseif (Clear-IniPair $lines '-data') { $changes++; Write-Log (T 'ini.set' '-data (removed)') }
    Write-Log (T 'ws' $Workspace $(if ($ForceWorkspace) { T 'ws.forced' } else { T 'ws.prompt' }))

    $vmIdx = $lines.IndexOf('-vmargs')
    if ($vmIdx -lt 0) { $lines.Add('-vmargs'); $vmIdx = $lines.Count - 1 }
    $custPath = Join-Path $Destination 'plugin_customization.ini'
    # prefix -> full line (-vmargs part)
    $vmSettings = [ordered]@{
        '-Dosgi.instance.area.default='  = "-Dosgi.instance.area.default=$Workspace"
        '-Declipse.pluginCustomization=' = "-Declipse.pluginCustomization=$custPath"
    }
    if ($MaxHeapMB) { $vmSettings['-Xmx'] = "-Xmx$($MaxHeapMB)m" }
    foreach ($prefix in $vmSettings.Keys) {
        if (Edit-IniValue $lines ($vmIdx + 1) $lines.Count $prefix $vmSettings[$prefix]) { $changes++; Write-Log (T 'ini.set' $vmSettings[$prefix]) }
    }
    if ($changes -eq 0) { Write-Log (T 'ini.same') }
    elseif ($PSCmdlet.ShouldProcess($iniPath, "$changes change(s)")) {
        if (-not (Test-Path "$iniPath.orig")) { Copy-Item $iniPath "$iniPath.orig" }
        Write-TextFile -Path $iniPath -Lines $lines
        Write-Log (T 'ini.saved' $changes) OK
    }

    # ---------- 3. plugin_customization.ini ----------
    Write-Log (T 'cust') STEP
    $custLines = @('# VDI-ImageMaint Install-Eclipse.ps1 - non-persistent VDI defaults (override the product plugin_customization.ini)') +
        @($Customization.Keys | ForEach-Object { '{0}={1}' -f $_, $Customization[$_] })
    $old = if (Test-Path $custPath) { @([IO.File]::ReadAllLines($custPath)) } else { @() }
    if (($old -join "`n") -ceq ($custLines -join "`n")) { Write-Log (T 'cust.same' $Customization.Count) }
    elseif ($PSCmdlet.ShouldProcess($custPath, "$($Customization.Count) preferences")) {
        Write-TextFile -Path $custPath -Lines $custLines
        Write-Log (T 'cust.saved' $Customization.Count $custPath) OK
    }
    Write-Log $(if ($AllowUserUpdates) { T 'updates.on' } else { T 'updates.off' })

    $jdks = @(Get-ChildItem -Path $AdoptiumDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'bin\javac.exe') } | ForEach-Object { $_.Name })
    if ($jdks.Count) { Write-Log (T 'jdks' ($jdks -join ', ')) OK } else { Write-Log (T 'jdks.none') WARN }

    # ---------- 4. shortcut + Uninstall entry ----------
    Write-Log (T 'shortcut' $Shortcut) STEP
    if ($PSCmdlet.ShouldProcess($Shortcut, 'create')) {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($Shortcut)
        $lnk.TargetPath = $exe
        $lnk.WorkingDirectory = $Destination
        $lnk.IconLocation = "$exe,0"
        $lnk.Description = $ProductName
        $lnk.Save()
    }

    $platform = ''
    $prod = Join-Path $Destination '.eclipseproduct'
    if (Test-Path $prod) {
        $pv = Select-String -Path $prod -Pattern '^version=(.+)$' | Select-Object -First 1
        if ($pv) { $platform = $pv.Matches[0].Groups[1].Value.Trim() }
    }
    $version = $(if ($installed -and -not $release) { $installed } else { $release })
    if ($PSCmdlet.ShouldProcess($ArpKey, "DisplayVersion=$version")) {
        if (-not (Test-Path $ArpKey)) { New-Item -Path $ArpKey -Force | Out-Null }
        $sizeKb = [int]((Get-ChildItem -Path $Destination -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1KB)
        $uninst = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Package {1} -Destination "{2}" -Uninstall' -f $PSCommandPath, $Package, $Destination
        $vals = [ordered]@{
            DisplayName = $ProductName; DisplayVersion = $version; Publisher = 'Eclipse Foundation'
            InstallLocation = $Destination; DisplayIcon = $exe; Comments = "Eclipse Platform $platform (VDI-ImageMaint)"
            UninstallString = $uninst; QuietUninstallString = $uninst
        }
        foreach ($k in $vals.Keys) { New-ItemProperty -Path $ArpKey -Name $k -Value ([string]$vals[$k]) -PropertyType String -Force | Out-Null }
        foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty -Path $ArpKey -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
        New-ItemProperty -Path $ArpKey -Name 'EstimatedSize' -Value $sizeKb -PropertyType DWord -Force | Out-Null
        Write-Log (T 'arp' $ProductName $version) OK
    }
    Write-Log (T 'next')
    }   # Test-Path $exe
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
