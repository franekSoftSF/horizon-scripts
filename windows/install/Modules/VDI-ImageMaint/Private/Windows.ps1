# Windows release awareness: which Windows 11 release the image runs, and whether the Horizon Agent and
# OSOT support it. Sources (check again for every new release):
#   Microsoft: Windows 11 release information (learn.microsoft.com/windows/release-health/windows11-release-information)
#   Omnissa KB 78714: supported Windows 11 guest OS per Horizon Agent version
#   Omnissa: supported Windows versions for the OSOT components
# HorizonMin / OsotMin = '' -> the release is not in the Omnissa support matrix yet (lab tests only).
# Horizon 2312.2/2312.3 (8.12.x ESB) also support 24H2/25H2 - see KB 78714.

$script:WindowsReleases = @(
    [pscustomobject]@{ Build = 26100; Release = '24H2'; Vdi = $true;  HorizonMin = '8.13'; OsotMin = '2503'; EndEntEdu = '2027-10-12'; EndPro = '2026-10-13' }
    [pscustomobject]@{ Build = 26200; Release = '25H2'; Vdi = $true;  HorizonMin = '8.17'; OsotMin = '2603'; EndEntEdu = '2028-10-10'; EndPro = '2027-10-12' }
    [pscustomobject]@{ Build = 26300; Release = '26H2'; Vdi = $true;  HorizonMin = '';     OsotMin = '';     EndEntEdu = '2029-10-09'; EndPro = '2028-10-10' }
    # 26H1 is only for new devices (Snapdragon X2 etc.) - not offered to existing devices, not a VDI guest
    [pscustomobject]@{ Build = 28000; Release = '26H1'; Vdi = $false; HorizonMin = '';     OsotMin = '';     EndEntEdu = '2029-03-13'; EndPro = '2028-03-14' }
)

# Horizon marketing version (YYMM) <-> internal version, for messages
$script:HorizonVersions = @{
    '8.12' = '2312'; '8.13' = '2406'; '8.14' = '2412'; '8.15' = '2503'; '8.16' = '2506'
    '8.17' = '2512'; '8.18' = '2603'; '8.19' = '2606'
}

# Silent install options (ADDLOCAL) of the Horizon Agent for Windows (Omnissa docs 2603)
$script:HorizonAgentFeatures = @(
    'ALL', 'Core', 'USB', 'NGVC', 'RTAV', 'ClientDriveRedirection', 'SerialPortRedirection', 'ScannerRedirection',
    'GEOREDIR', 'SmartCard', 'HznVaudio', 'TSMMR', 'RDP', 'RDSH3D', 'BlastUDP', 'SdoSensor', 'PerfTracker',
    'HelpDesk', 'PrintRedir', 'PSG', 'StorageDriveRedir'
)
# Defaults per image profile (Core includes Blast, PCoIP, Media Optimization for Teams, HTML5 MMR, Browser Redirection)
$script:HorizonAgentProfileFeatures = @{
    University = 'Core,NGVC,RTAV,ClientDriveRedirection,HznVaudio,BlastUDP,PrintRedir,HelpDesk,USB'
    Business   = 'Core,NGVC,RTAV,ClientDriveRedirection,HznVaudio,BlastUDP,PrintRedir,HelpDesk,USB,ScannerRedirection'
    Graphics   = 'Core,NGVC,RTAV,ClientDriveRedirection,HznVaudio,BlastUDP,PrintRedir,HelpDesk,USB'
}

function Get-WindowsRelease {
    # The running Windows: build, UBR, release name and its row in $WindowsReleases (or $null)
    param([int]$Build = 0)
    $nt = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $ubr = 0
    if (-not $Build) {
        $Build = [int](Get-RegValue $nt 'CurrentBuildNumber')
        $ubr   = [int](Get-RegValue $nt 'UBR')
    }
    $info = @($script:WindowsReleases | Where-Object { $_.Build -eq $Build }) | Select-Object -First 1
    $name = $(if ($info) { $info.Release } else { [string](Get-RegValue $nt 'DisplayVersion') })
    return [pscustomobject]@{
        Build = $Build; UBR = $ubr; Release = $name; Edition = [string](Get-RegValue $nt 'EditionID'); Info = $info
    }
}

function Get-HorizonAgentVersion {
    # Internal version (8.17.0) from an installer name (Omnissa-Horizon-Agent-x86_64-2512-8.17.0-12345678.exe)
    # or from a version text; '' when unknown
    param([string]$Text)
    if ($Text -match '(?<!\d)(8\.\d{1,2}\.\d+)(?:\.\d+)?(?!\d)') { return $Matches[1] }
    if ($Text -match '(?<!\d)(2[3-9][01]\d)(?:\.(\d))?(?!\d)') {
        $yymm = $Matches[1]; $patch = $(if ($Matches[2]) { $Matches[2] } else { '0' })
        foreach ($k in $script:HorizonVersions.Keys) { if ($script:HorizonVersions[$k] -eq $yymm) { return "$k.$patch" } }
    }
    return ''
}

function Get-HorizonMarketingName {
    param([string]$Version)
    if ($Version -match '^(8\.\d+)\.(\d+)') {
        $yymm = $script:HorizonVersions[$Matches[1]]
        if ($yymm) { return $(if ($Matches[2] -ne '0') { "$yymm.$($Matches[2])" } else { $yymm }) }
    }
    return $Version
}

function Test-HorizonAgentSupport {
    # ok | old (agent older than the first version supporting the release) | unlisted (release not in the
    # Omnissa matrix yet) | novdi (release is not a VDI guest) | unknown (release or agent version unknown)
    param([string]$AgentVersion, $Release)
    if (-not $Release -or -not $Release.Info) { return 'unknown' }
    if (-not $Release.Info.Vdi) { return 'novdi' }
    if (-not $Release.Info.HorizonMin) { return 'unlisted' }
    if (-not $AgentVersion) { return 'unknown' }
    try { $a = [version]$AgentVersion; $min = [version]$Release.Info.HorizonMin } catch { return 'unknown' }
    if ($a -lt $min) { return 'old' } else { return 'ok' }
}

function Get-HorizonAgentSupportText {
    # Localized one-line verdict for logs and the package plan; '' when everything is fine
    param([string]$AgentVersion, $Release)
    $r = Test-HorizonAgentSupport -AgentVersion $AgentVersion -Release $Release
    $agent = Get-HorizonMarketingName $AgentVersion
    switch ($r) {
        'old'      { return (T 'win.hz.old' $agent $Release.Release (Get-HorizonMarketingName "$($Release.Info.HorizonMin).0")) }
        'unlisted' { return (T 'win.hz.unlisted' $Release.Release) }
        'novdi'    { return (T 'win.novdi' $Release.Release) }
        default    { return '' }
    }
}

function Write-WindowsReleaseInfo {
    # One line about the running release + warnings (unsupported by Horizon/OSOT, end of servicing)
    $rel = Get-WindowsRelease
    Write-Log (T 'win.release' $rel.Release $rel.Build $rel.UBR $rel.Edition)
    if (-not $rel.Info) { Write-Log (T 'win.unknown' $rel.Build) WARN; return }
    if (-not $rel.Info.Vdi) { Write-Log (T 'win.novdi' $rel.Release) ERR; return }
    if (-not $rel.Info.HorizonMin) { Write-Log (T 'win.hz.unlisted' $rel.Release) WARN }
    if (-not $rel.Info.OsotMin) { Write-Log (T 'win.osot.unlisted' $rel.Release) WARN }
    $end = $(if ($rel.Edition -match '^(Enterprise|Education)') { $rel.Info.EndEntEdu } else { $rel.Info.EndPro })
    $days = ([datetime]::ParseExact($end, 'yyyy-MM-dd', $null) - (Get-Date)).Days
    if ($days -lt 0) { Write-Log (T 'win.endPassed' $rel.Release $rel.Edition $end) ERR }
    elseif ($days -lt 180) { Write-Log (T 'win.endSoon' $rel.Release $rel.Edition $end $days) WARN }

    $agent = @(Get-InstalledApps | Where-Object { $_.Name -match 'Horizon Agent$' }) | Select-Object -First 1
    if ($agent) {
        $txt = Get-HorizonAgentSupportText -AgentVersion (Get-HorizonAgentVersion ([string]$agent.Version)) -Release $rel
        if ($txt) { Write-Log $txt WARN }
    }
}

function Test-FeatureUpdate {
    # Windows Update item that moves the image to another release (feature update / enablement package).
    # The category is language-neutral; the English title check is only a fallback.
    param($Update)
    foreach ($c in @($Update.Categories)) {
        if ([string]$c.CategoryID -eq '3689bdc8-b205-4af4-8d4a-a63924c5e9d5') { return $true }   # "Upgrades"
    }
    return ([string]$Update.Title -match '(?i)feature update|enablement package')
}

function Get-TargetRelease {
    # Windows.TargetRelease from the manifest ('' = stay on the current release)
    $m = Get-PackageManifest
    return [string](Get-PV (Get-PV $m 'Windows') 'TargetRelease' '')
}

function Set-TargetReleasePolicy {
    # Windows Update for Business: offer exactly this release (and nothing newer)
    param([string]$Release)
    $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    Set-ItemProperty -Path $k -Name 'TargetReleaseVersion' -Value 1 -Type DWord
    Set-ItemProperty -Path $k -Name 'ProductVersion' -Value 'Windows 11' -Type String
    Set-ItemProperty -Path $k -Name 'TargetReleaseVersionInfo' -Value $Release -Type String
    Write-Log (T 'win.target.policy' $Release) OK
}
