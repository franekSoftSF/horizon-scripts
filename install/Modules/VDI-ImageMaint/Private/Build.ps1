# Image build: Generalize (Sysprep) and automatic continuation after OOBE (PostGeneralize); running as SYSTEM.
# Omnissa order: Optimize -> Generalize -> Horizon/DEM/App Volumes agents -> Finalize.
# Generalize runs ONCE per Windows release (audit mode). The Day-2 cycle (Update/Seal) never repeats it.
# Continuation: unattend.xml (AutoLogon + FirstLogonCommands) starts -Mode PostGeneralize after OOBE;
# further reboots (agents) use the regular AtLogOn resume (-AutoReboot).

function Get-BuildConfig {
    # Optional "Build" section of the manifest. Default regional settings = the current system settings,
    # because UILanguage MUST be an installed language (otherwise OOBE fails).
    $m = $null
    $mp = Get-ManifestPath
    if (Test-Path $mp) { try { $m = Get-Content -Path $mp -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $b = Get-PV $m 'Build'
    $culture = (Get-Culture).Name
    # an empty string in the manifest = default value
    $str = { param($Name, $Default) $v = [string](Get-PV $b $Name ''); if ($v.Trim()) { $v.Trim() } else { $Default } }
    [ordered]@{
        TimeZone                 = & $str 'TimeZone' (Get-TimeZone).Id
        InputLocale              = & $str 'InputLocale' $culture
        SystemLocale             = & $str 'SystemLocale' (Get-WinSystemLocale).Name
        UILanguage               = & $str 'UILanguage' ([Globalization.CultureInfo]::InstalledUICulture.Name)
        UserLocale               = & $str 'UserLocale' $culture
        ComputerName             = & $str 'ComputerName' $env:COMPUTERNAME
        SkipRearm                = [bool](Get-PV $b 'SkipRearm' $false)
        PersistAllDeviceInstalls = [bool](Get-PV $b 'PersistAllDeviceInstalls' $true)
        SysprepVmMode            = [bool](Get-PV $b 'SysprepVmMode' $false)
        KeepBitLocker            = [bool](Get-PV $b 'KeepBitLocker' $false)
        AutoLogonCount           = [int](Get-PV $b 'AutoLogonCount' 10)
        PostGeneralizePackages   = @(Get-PV $b 'PostGeneralizePackages' @('VMwareTools', 'HorizonAgent', 'DEM', 'AppVolumesAgent'))
        RemoveUserAppx           = @(Get-PV $b 'RemoveUserAppx' @('Microsoft.Copilot', 'Microsoft.BingSearch'))
        AppxSettleSeconds        = [int](Get-PV $b 'AppxSettleSeconds' 120)
    }
}

function Set-BuildStage {
    param([string]$Stage)
    [pscustomobject]@{ Stage = $Stage; Updated = (Get-Date).ToString('s'); Computer = $env:COMPUTERNAME } |
        ConvertTo-Json | Set-Content -Path $BuildStateFile -Encoding UTF8
    Write-Log (T 'bld.stage' $Stage)
}

function Get-BuildStage {
    if (-not (Test-Path $BuildStateFile)) { return '' }
    try { return [string](Get-PV (Get-Content -Path $BuildStateFile -Raw | ConvertFrom-Json) 'Stage' '') } catch { return '' }
}

function Test-AuditMode {
    $state = [string](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' 'ImageState')
    return ((Test-Path 'HKLM:\SYSTEM\Setup\Status\AuditBoot') -or $state -match 'RESEAL_TO_AUDIT|UNDEPLOYABLE')
}

function Get-BuiltinAdminName {
    # Name of the RID 500 account (may be renamed or localized)
    $u = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -match '-500$' } | Select-Object -First 1
    if ($u) { return $u.Name } else { return 'Administrator' }
}

function Get-UnprovisionedAppx {
    # Packages installed for an account but not provisioned - the main cause of Sysprep error 0x80073cf2
    $prov = @{}
    foreach ($p in @(Get-AppxProvisionedPackage -Online)) { $prov[[string]$p.DisplayName] = $true }
    foreach ($a in @(Get-AppxPackage -AllUsers)) {
        if ((Get-PV $a 'IsFramework' $false) -or (Get-PV $a 'IsResourcePackage' $false) -or (Get-PV $a 'NonRemovable' $false)) { continue }
        if ([string](Get-PV $a 'SignatureKind' '') -eq 'System') { continue }
        if ($prov.ContainsKey([string]$a.Name)) { continue }
        $inst = @(@(Get-PV $a 'PackageUserInformation' @()) | Where-Object { [string]$_.InstallState -eq 'Installed' })
        if ($inst.Count) { $a }
    }
}

function Remove-UserAppx {
    param([string[]]$Names)
    foreach ($n in $Names) {
        foreach ($a in @(Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue)) {
            try { Remove-AppxPackage -Package $a.PackageFullName -AllUsers -ErrorAction Stop; Write-Log (T 'bld.appxRemoved' $a.PackageFullName) OK }
            catch { Write-Log "AppX $($a.PackageFullName): $($_.Exception.Message)" WARN }
        }
    }
}

function Wait-VolumeDecrypted {
    # Device encryption (Win11 24H2/25H2 with vTPM) blocks Sysprep when leaving audit mode
    param([int]$TimeoutMinutes = 180)
    $vol = $null
    try {
        $vol = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$($env:SystemDrive)'" -ErrorAction Stop
    } catch { return $true }   # no BitLocker on this system
    if (-not $vol) { return $true }
    $cs = Invoke-CimMethod -InputObject $vol -MethodName GetConversionStatus
    if ([int]$cs.ConversionStatus -eq 0) { return $true }
    Write-Log (T 'bld.encrypted' $env:SystemDrive $cs.ConversionStatus $cs.EncryptionPercentage) WARN
    & manage-bde.exe -off $env:SystemDrive | Out-Null
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 30
        $cs = Invoke-CimMethod -InputObject $vol -MethodName GetConversionStatus
        Write-Log (T 'bld.decrypting' $cs.ConversionStatus $cs.EncryptionPercentage)
    } while ([int]$cs.ConversionStatus -ne 0 -and (Get-Date) -lt $deadline)
    return ([int]$cs.ConversionStatus -eq 0)
}

function Invoke-SysprepRemediation {
    param($Cfg)
    Write-Log (T 'bld.remediation') STEP
    # Store updates for the account = packages newer than provisioned (0x80073cf2)
    $store = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
    if ((Get-RegValue $store 'AutoDownload') -ne 2) {
        if (-not (Test-Path $store)) { New-Item -Path $store -Force | Out-Null }
        New-ItemProperty -Path $store -Name AutoDownload -Value 2 -PropertyType DWord -Force | Out-Null
        Write-Log 'Store AutoDownload=2' OK
    }
    if (-not $Cfg.KeepBitLocker) {
        $bl = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'
        if (-not (Test-Path $bl)) { New-Item -Path $bl -Force | Out-Null }
        New-ItemProperty -Path $bl -Name PreventDeviceEncryption -Value 1 -PropertyType DWord -Force | Out-Null
        if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\BDESVC') {
            try { Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\BDESVC' -Name Start -Value 4 -ErrorAction Stop } catch { Write-Log "BDESVC: $($_.Exception.Message)" WARN }
        }
        Write-Log (T 'bld.noEncryption') OK
        if (-not (Wait-VolumeDecrypted)) { throw (T 'bld.stillEncrypted' $env:SystemDrive) }
    }
    Remove-UserAppx -Names $Cfg.RemoveUserAppx
    foreach ($a in @(Get-UnprovisionedAppx)) {
        if ($a.Name -eq 'MSTeams') {
            Write-Log (T 'bld.teamsUser') WARN
        } elseif ($RemoveUnprovisionedAppx) {
            Remove-UserAppx -Names @($a.Name)
        } else {
            Write-Log (T 'bld.appxUser' $a.PackageFullName) WARN
        }
    }
}

function Invoke-ReadinessCheck {
    # Test-SysprepReadiness.ps1: C:\install\Scripts (next to the entry script) or any subfolder of C:\install
    $root = Split-Path $script:EntryScript
    $cands = @((Join-Path $root 'Scripts\Test-SysprepReadiness.ps1'), (Join-Path $root 'Test-SysprepReadiness.ps1'))
    $checker = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $checker -and (Test-Path $InstallDir)) {
        $hit = Get-ChildItem -Path $InstallDir -Recurse -File -Filter 'Test-SysprepReadiness.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $checker = $hit.FullName }
    }
    if (-not $checker) {
        if ($Force) { Write-Log (T 'bld.noCheckerForce') WARN; return }
        throw (T 'bld.noChecker')
    }
    Write-Log (T 'bld.check' $checker) STEP
    $json = Join-Path $LogDir ('SysprepReadiness_{0}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $lang = $(if ($script:UICultureName -eq 'pl-PL') { 'pl' } else { 'en' })
    $p = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -NoNewWindow -ArgumentList (
        '-NoProfile -ExecutionPolicy Bypass -File "{0}" -InstallDir "{1}" -OutFile "{2}" -Language {3}' -f $checker, $InstallDir, $json, $lang)
    if (Test-Path $json) {
        $r = Get-Content -Path $json -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($x in @($r.Results | Where-Object { $_.Status -in 'FAIL', 'WARN' })) {
            Write-Log ("{0} {1}: {2}" -f $x.Id, $x.Check, $x.Detail) $(if ($x.Status -eq 'FAIL') { 'ERR' } else { 'WARN' })
        }
    }
    if ($p.ExitCode -ge 2) {
        if ($Force) { Write-Log (T 'bld.checkFailForce') WARN }
        else { throw (T 'bld.checkFail' $json) }
    } else {
        Write-Log (T 'bld.checkCode' $p.ExitCode) $(if ($p.ExitCode -eq 0) { 'OK' } else { 'WARN' })
    }
}

function New-UnattendXml {
    param($Cfg, [securestring]$Password, [string]$FirstLogonCommand)
    $esc = { param($s) [Security.SecurityElement]::Escape([string]$s) }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    # WSIM "PlainText=false" format: Base64(UTF-16LE(password + field name)); Windows Setup removes passwords from the Panther copy
    $admPwd   = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($plain + 'AdministratorPassword'))
    $logonPwd = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($plain + 'Password'))
    $plain = $null
    $admin = Get-BuiltinAdminName
    $c = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
    $rearm = if ($Cfg.SkipRearm) { @"

    <component name="Microsoft-Windows-Security-SPP" $c>
      <SkipRearm>1</SkipRearm>
    </component>
"@ } else { '' }
    return @"
<?xml version="1.0" encoding="utf-8"?>
<!-- VDI-ImageMaint: Generalize ($(Get-Date -Format 'yyyy-MM-dd HH:mm')). The file is deleted after OOBE. -->
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="generalize">
    <component name="Microsoft-Windows-PnpSysprep" $c>
      <PersistAllDeviceInstalls>$(([string]$Cfg.PersistAllDeviceInstalls).ToLower())</PersistAllDeviceInstalls>
    </component>$rearm
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $c>
      <ComputerName>$(& $esc $Cfg.ComputerName)</ComputerName>
      <TimeZone>$(& $esc $Cfg.TimeZone)</TimeZone>
    </component>
    <component name="Microsoft-Windows-Deployment" $c>
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>net user "$(& $esc $admin)" /active:yes</Path>
          <Description>Enable built-in administrator for AutoLogon</Description>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $c>
      <InputLocale>$(& $esc $Cfg.InputLocale)</InputLocale>
      <SystemLocale>$(& $esc $Cfg.SystemLocale)</SystemLocale>
      <UILanguage>$(& $esc $Cfg.UILanguage)</UILanguage>
      <UserLocale>$(& $esc $Cfg.UserLocale)</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $c>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$admPwd</Value>
          <PlainText>false</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$(& $esc $admin)</Username>
        <LogonCount>$([int]$Cfg.AutoLogonCount)</LogonCount>
        <Password>
          <Value>$logonPwd</Value>
          <PlainText>false</PlainText>
        </Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>$(& $esc $FirstLogonCommand)</CommandLine>
          <Description>VDI-ImageMaint PostGeneralize</Description>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>
      <TimeZone>$(& $esc $Cfg.TimeZone)</TimeZone>
    </component>
  </settings>
</unattend>
"@
}

function Read-AdminPassword {
    if ($AdminPassword) { return $AdminPassword }
    $admin = Get-BuiltinAdminName
    for ($i = 0; $i -lt 3; $i++) {
        $p1 = Read-Host -AsSecureString (T 'bld.pwd' $admin)
        $p2 = Read-Host -AsSecureString (T 'bld.pwdRepeat')
        $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1); $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2)
        try {
            $same = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1) -ceq [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
            $empty = $p1.Length -eq 0
        } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2) }
        if ($same -and -not $empty) { return $p1 }
        Write-Log (T 'bld.pwdMismatch') WARN
    }
    throw (T 'bld.pwdNone')
}

function Invoke-Generalize {
    Write-Log (T 'bld.step') STEP
    if ($isSystem) { throw (T 'bld.notSystem') }
    if (-not (Test-AuditMode)) {
        if ($Force) { Write-Log (T 'bld.noAuditForce') WARN }
        else { throw (T 'bld.noAudit') }
    }
    if (-not $SnapshotConfirmed) { throw (T 'bld.snapshot') }
    $pending = @(Test-PendingReboot | Where-Object { $_ -ne 'PendingFileRename' })
    if ($pending.Count) { throw (T 'bld.pending' ($pending -join ', ')) }
    if ($GeneralizeEngine -eq 'Osot' -and -not $SkipOsot -and -not (Find-Osot)) { throw (T 'bld.noOsot' $InstallDir) }

    $cfg = Get-BuildConfig
    Write-Log (T 'bld.oobe' $cfg.TimeZone $cfg.UILanguage $cfg.SystemLocale $cfg.UserLocale $cfg.InputLocale $cfg.ComputerName)
    Invoke-SysprepRemediation -Cfg $cfg
    Invoke-ReadinessCheck
    $admPass = Read-AdminPassword

    # After OOBE: AutoLogon -> FirstLogonCommands -> PostGeneralize (1024 character limit, hence -File)
    $cont = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode PostGeneralize -InstallDir "{1}"' -f $script:EntryScript, $InstallDir
    if ($Manifest) { $cont += ' -Manifest "{0}"' -f (Get-ManifestPath) }
    if ($Shutdown) { $cont += ' -Shutdown' }
    if ($script:BoundParams.ContainsKey('Language')) { $cont += " -Language $Language" }
    if ($cont.Length -gt 1000) { throw (T 'bld.cmdTooLong' $cont.Length) }

    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
    # The file contains the (encoded) password - access for SYSTEM and Administrators only
    & icacls.exe $BuildDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    $xml = New-UnattendXml -Cfg $cfg -Password $admPass -FirstLogonCommand $cont
    [IO.File]::WriteAllText($UnattendPath, $xml, (New-Object System.Text.UTF8Encoding($false)))
    [void][xml](Get-Content -Path $UnattendPath -Raw)   # XML syntax check
    Write-Log "unattend.xml: $UnattendPath" OK
    Set-BuildStage 'Generalizing'

    if ($GeneralizeEngine -eq 'Osot' -and -not $SkipOsot) {
        # -g without -reboot: reboot only after confirming that Sysprep succeeded
        Invoke-Osot -Label 'Generalize' -Arguments @('-g', $UnattendPath, '-v')
    } else {
        $sp = Join-Path $env:SystemRoot 'System32\Sysprep\sysprep.exe'
        $a = "/generalize /oobe /quit /unattend:`"$UnattendPath`""
        if ($cfg.SysprepVmMode) { $a += ' /mode:vm' }
        Write-Log "sysprep.exe $a" STEP
        [void](Start-Process -FilePath $sp -ArgumentList $a -Wait -PassThru)
    }
    # OSOT may start sysprep.exe asynchronously - wait for it to finish
    $deadline = (Get-Date).AddMinutes(60)
    while ((Get-Process -Name sysprep -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }

    $state = [string](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' 'ImageState')
    if ($state -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
        $err = Join-Path $env:SystemRoot 'System32\Sysprep\Panther\setuperr.log'
        if (Test-Path $err) { Get-Content -Path $err -Tail 15 | ForEach-Object { Write-Log "  $_" ERR } }
        Set-BuildStage 'GeneralizeFailed'
        throw (T 'bld.sysprepFailed' $state $err)
    }
    Set-BuildStage 'Generalized'
    Write-Log (T 'bld.sysprepOk') OK
    Write-Log (T 'upd.rebootIn' 15) WARN
    try { Stop-Transcript | Out-Null } catch { }
    Start-Sleep -Seconds 15
    Restart-Computer -Force
    Stop-ForRestart
}

function Disable-AutoLogon {
    Set-ItemProperty -Path $WinlogonKey -Name AutoAdminLogon -Value '0'
    foreach ($n in 'DefaultPassword', 'AutoLogonCount') { Remove-ItemProperty -Path $WinlogonKey -Name $n -ErrorAction SilentlyContinue }
    Write-Log (T 'bld.autologonOff') OK
}

function Invoke-PostGeneralize {
    Write-Log (T 'bld.postStep') STEP
    # The unattend source holds an (encoded) password - delete it; Windows removes passwords from the Panther copy
    if (Test-Path $BuildDir) { Remove-Item -Path $BuildDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Log (T 'bld.removed' $BuildDir) }
    $stage = Get-BuildStage
    if ($stage -notin 'Generalized', 'PostGeneralize') { Write-Log (T 'bld.unexpectedStage' $stage) WARN }
    Set-BuildStage 'PostGeneralize'
    $cfg = Get-BuildConfig

    # Further rounds (reboots after the agents) resume via the AtLogOn task; AutoLogon signs the administrator in
    $script:AutoReboot = [System.Management.Automation.SwitchParameter]::Present
    $script:BoundParams['AutoReboot'] = [System.Management.Automation.SwitchParameter]::Present

    if ($ResumeRound -eq 0 -and $cfg.AppxSettleSeconds -gt 0) {
        Write-Log (T 'bld.appxWait' $cfg.AppxSettleSeconds)
        Start-Sleep -Seconds $cfg.AppxSettleSeconds
    }
    Remove-UserAppx -Names $cfg.RemoveUserAppx

    Write-Log (T 'bld.agents' ($cfg.PostGeneralizePackages -join ', ')) STEP
    $script:ForceInstallIds = @($cfg.PostGeneralizePackages)
    $script:PackageIds      = @($cfg.PostGeneralizePackages)
    Invoke-PackagePlatform          # with RebootAfter: reboot + resume (ends the run)
    if ($script:PackageRunResult -eq 'error') { throw (T 'bld.manifestError') }
    $script:ForceInstallIds = @()

    $pending = @(Test-PendingReboot | Where-Object { $_ -ne 'PendingFileRename' })
    if ($pending.Count) {
        Write-Log (T 'bld.pendingBeforeSeal' ($pending -join ', ')) WARN
        Request-RebootAndResume
        return
    }

    Disable-AutoLogon
    $script:BuildFinalize = $true
    $rc = Invoke-SealAsSystemFlow
    if ($rc -ne 0) { throw (T 'upd.sealFailed' $rc) }
    Set-BuildStage 'Done'
    Write-Log (T 'bld.done') OK
    Write-Log (T 'seal.next') STEP
}

# ---------- running as SYSTEM ----------
function Invoke-AsSystem {
    param([string]$TargetMode = $Mode)
    # B5: forward ALL call parameters (e.g. -NoBlockDetected, -InstallDir, -Manifest, detection patterns),
    # except those handled by the parent process
    $argText = ConvertTo-ArgumentText -Params $script:BoundParams -Exclude @('Mode', 'AsSystem', 'Shutdown', 'ResumeRound', 'AutoReboot', 'ThenSeal', 'AdminPassword', 'SnapshotConfirmed')
    $cmd = "& '{0}' -Mode {1} {2}; exit `$LASTEXITCODE" -f ($script:EntryScript -replace "'", "''"), $TargetMode, $argText
    $taskName = 'VDI-ImageMaint-AsSystem'
    $start    = Get-Date

    Write-Log "SYSTEM: $cmd"
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + (ConvertTo-EncodedCommand $cmd))
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null

    Write-Log (T 'sys.start' $TargetMode) STEP
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 3
    while ((Get-ScheduledTask -TaskName $taskName).State -in 'Running', 'Queued') { Start-Sleep -Seconds 3 }
    $rc = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

    $log = Get-ChildItem -Path $LogDir -Filter "$($TargetMode)_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $start } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($log) { Get-Content -Path $log.FullName | Write-Host; Write-Log (T 'sys.log' $log.FullName) }
    return [int]$rc
}
