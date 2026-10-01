# Update cycle: Unlock -> OSOT enable updates -> packages -> winget installs -> Defender -> Office -> VS -> Edge ->
# Teams -> winget updates -> Windows Update; reboot and resume (AtLogOn task) with -AutoReboot; optional -ThenSeal.

function Get-ResumeCommand {
    $a = ConvertTo-ArgumentText -Params $script:BoundParams -Exclude @('ResumeRound')
    return ("& '{0}' {1} -ResumeRound {2}" -f ($script:EntryScript -replace "'", "''"), $a, ($ResumeRound + 1))
}

function Request-RebootAndResume {
    if (-not $AutoReboot) {
        Write-Log (T 'upd.rebootManual') WARN
        return
    }
    if ($ResumeRound -ge $MaxRounds) { Write-Log (T 'upd.maxRounds' $MaxRounds) ERR; return }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $cmd  = Get-ResumeCommand
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -NoExit -EncodedCommand ' + (ConvertTo-EncodedCommand $cmd))
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $ResumeTaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-Log (T 'upd.resume' $user ($ResumeRound + 1) $MaxRounds $cmd)
    Write-Log (T 'upd.rebootIn' 20) WARN
    try { Stop-Transcript | Out-Null } catch { }
    Start-Sleep -Seconds 20
    Restart-Computer -Force
    Stop-ForRestart
}

function Update-Defender {
    Write-Log (T 'upd.defender') STEP
    try { Update-MpSignature -ErrorAction Stop; Write-Log (T 'upd.defenderOk') OK }
    catch { Write-Log (T 'upd.defenderSkip' $_.Exception.Message) }
}

function Test-OdtConfig {
    param([string]$Path)
    try { [xml]$x = Get-Content -Path $Path -Raw } catch { Write-Log (T 'odt.xmlError' $_.Exception.Message) ERR; return $false }
    $add = $x.SelectSingleNode('/Configuration/Add')
    if (-not $add) { Write-Log (T 'odt.noAdd') ERR; return $false }
    $ver = $add.GetAttribute('Version')
    Write-Log (T 'odt.info' $add.GetAttribute('Channel') $add.GetAttribute('SourcePath') $(if ($ver) { $ver } else { T 'odt.latest' }))
    $upd = $x.SelectSingleNode('/Configuration/Updates')
    if ($upd -and $upd.GetAttribute('Enabled') -match '^true$') { Write-Log (T 'odt.updatesOn') WARN }
    $scl = $x.SelectSingleNode("/Configuration/Property[@Name='SharedComputerLicensing']")
    if (-not $scl -or $scl.GetAttribute('Value') -ne '1') { Write-Log (T 'odt.noScl') WARN }
    $fas = $x.SelectSingleNode("/Configuration/Property[@Name='FORCEAPPSHUTDOWN']")
    if (-not $fas -or $fas.GetAttribute('Value') -notmatch '^true$') { Write-Log (T 'odt.noForce') WARN }
    $disp = $x.SelectSingleNode('/Configuration/Display')
    if (-not $disp -or $disp.GetAttribute('Level') -ne 'None') { Write-Log (T 'odt.display') WARN }
    return $true
}

function Update-OfficeOdt {
    param([string]$Odt, [string]$Xml)
    $cfg = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $before = Get-RegValue $cfg 'VersionToReport'
    Write-Log (T 'odt.start' $Odt $before)
    if (-not (Test-OdtConfig $Xml)) { return $false }

    Write-Log (T 'odt.download')
    $p = Start-Process -FilePath $Odt -ArgumentList "/download `"$Xml`"" -WorkingDirectory (Split-Path $Odt) -Wait -PassThru
    if ($p.ExitCode -ne 0) { Write-Log (T 'odt.downloadFailed' $p.ExitCode) ERR; return $false }
    Write-Log (T 'odt.downloadOk') OK

    Write-Log (T 'odt.configure')
    $p = Start-Process -FilePath $Odt -ArgumentList "/configure `"$Xml`"" -WorkingDirectory (Split-Path $Odt) -Wait -PassThru
    $after = Get-RegValue $cfg 'VersionToReport'
    if ($p.ExitCode -ne 0) { Write-Log (T 'odt.configureFailed' $p.ExitCode) ERR; return $false }
    if ($after -ne $before) { Write-Log "Microsoft 365: $before -> $after" OK }
    else { Write-Log (T 'odt.unchanged' $after) OK }
    return $true
}

function Update-Office {
    if ($script:OfficeHandled) { return }   # already updated by the ODT package of the manifest
    Write-Log (T 'c2r.step') STEP
    $c2r = Join-Path $env:CommonProgramFiles 'microsoft shared\ClickToRun\OfficeC2RClient.exe'
    if (-not (Test-Path $c2r)) { Write-Log (T 'c2r.missing'); return }
    $cfg = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $before = Get-RegValue $cfg 'VersionToReport'
    Write-Log (T 'c2r.before' $before (Get-RegValue $cfg 'CDNBaseUrl'))
    Start-Process -FilePath $c2r -ArgumentList '/update user updatepromptuser=false forceappshutdown=true displaylevel=false' -Wait
    $deadline = (Get-Date).AddMinutes($OfficeWaitMinutes)
    do {
        Start-Sleep -Seconds 15
        $running = [bool](Get-Process -Name OfficeC2RClient -ErrorAction SilentlyContinue)
        $now = Get-RegValue $cfg 'VersionToReport'
    } while (($running -or $now -eq $before) -and (Get-Date) -lt $deadline)
    if ($now -ne $before) { Write-Log "Microsoft 365: $before -> $now" OK }
    else { Write-Log (T 'c2r.unchanged' $OfficeWaitMinutes) WARN }
}

function Update-VisualStudio {
    Write-Log 'Visual Studio' STEP
    $inst    = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
    $vswhere = Join-Path $inst 'vswhere.exe'
    $setup   = Join-Path $inst 'setup.exe'
    if (-not ((Test-Path $vswhere) -and (Test-Path $setup))) { Write-Log (T 'vs.missing'); return }
    foreach ($p in @(& $vswhere -all -prerelease -property installationPath)) {
        if (-not $p) { continue }
        Write-Log (T 'vs.update' $p)
        $proc = Start-Process -FilePath $setup -ArgumentList @('update', '--installPath', "`"$p`"", '--quiet', '--norestart') -Wait -PassThru
        switch ($proc.ExitCode) {
            0       { Write-Log (T 'vs.ok') OK }
            3010    { Write-Log (T 'vs.reboot') WARN }
            default { Write-Log (T 'vs.code' $proc.ExitCode) WARN }
        }
    }
}

function Update-Edge {
    Write-Log 'Microsoft Edge' STEP
    $eu = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe'
    if (-not (Test-Path $eu)) { Write-Log (T 'edge.missing'); return }
    Start-Process -FilePath $eu -ArgumentList '/ua /installsource scheduler' -Wait
    Write-Log (T 'edge.ok') OK
}

function Test-TrustedFile {
    # Runs/uses only files with a valid Authenticode signature from the expected publisher
    param([string]$Path, [string]$SignerPattern)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    return ($sig.Status -eq 'Valid' -and [string]$sig.SignerCertificate.Subject -match $SignerPattern)
}

function Update-Teams {
    Write-Log (T 'teams.step') STEP
    $prov = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'MSTeams' }) | Select-Object -First 1
    if (-not $prov) { Write-Log (T 'teams.notProvisioned'); return }
    Write-Log (T 'teams.before' $prov.Version)

    $bs = $TeamsBootstrapperPath
    if (-not $bs) {
        # next to the entry script or anywhere in C:\install (e.g. Teams\)
        $local = Join-Path (Split-Path $script:EntryScript) 'teamsbootstrapper.exe'
        if (Test-Path $local) { $bs = $local }
        elseif (Test-Path $InstallDir) {
            $hit = Get-ChildItem -Path $InstallDir -Recurse -File -Filter 'teamsbootstrapper.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $bs = $hit.FullName }
        }
    }
    if (-not $bs -or -not (Test-Path $bs)) {
        $bs = Join-Path $env:TEMP 'teamsbootstrapper.exe'
        Write-Log (T 'teams.download')
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409' -OutFile $bs -UseBasicParsing
        } catch { Write-Log (T 'teams.downloadFailed' $_.Exception.Message) WARN; return }
    }
    if (-not (Test-TrustedFile -Path $bs -SignerPattern 'O=Microsoft Corporation')) {
        Write-Log (T 'teams.badSignature' $bs) ERR
        return
    }

    # Offline provisioning when the MSIX lies next to the bootstrapper (-Mode Download puts both in Teams\)
    $bsArgs = @('-p')
    $msix = Join-Path (Split-Path $bs) 'MSTeams-x64.msix'
    if (Test-Path $msix) { $bsArgs += @('-o', $msix); Write-Log (T 'teams.offline' $msix) }

    $ErrorActionPreference = 'Continue'
    $out = & $bs @bsArgs 2>&1 | Out-String
    $rc  = $LASTEXITCODE
    Write-Log (T 'teams.result' $rc (($out -replace '\s+', ' ').Trim()))

    $after = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'MSTeams' }) | Select-Object -First 1
    if ($after -and $after.Version -ne $prov.Version) { Write-Log "Teams: $($prov.Version) -> $($after.Version)" OK }
    elseif ($rc -eq 0) { Write-Log (T 'teams.current') }
    else { Write-Log (T 'teams.failed') WARN }
}

function Update-Windows {
    Write-Log (T 'wu.step') STEP
    $wu = 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv'
    if ((Get-RegValue $wu 'Start') -eq 4) {
        Write-Log (T 'wu.disabled') WARN
        try { Set-ItemProperty -Path $wu -Name Start -Value 3 -ErrorAction Stop } catch { Write-Log (T 'wu.cannotChange') ERR; return }
    }
    # A feature update / enablement package moves the golden image to another release (Horizon and OSOT
    # support differ per release) - only with Windows.TargetRelease in the manifest
    $rel    = Get-WindowsRelease
    $target = Get-TargetRelease
    $allowFeature = $false
    if ($target -and $target -ne $rel.Release) {
        Write-Log (T 'win.target.up' $target) WARN
        $tInfo = @($script:WindowsReleases | Where-Object { $_.Release -eq $target }) | Select-Object -First 1
        if ($tInfo -and -not $tInfo.Vdi) { Write-Log (T 'win.novdi' $target) ERR; return }
        if ($tInfo -and -not $tInfo.HorizonMin) { Write-Log (T 'win.hz.unlisted' $target) WARN }
        Set-TargetReleasePolicy $target
        $allowFeature = $true
    } elseif ($target) { Write-Log (T 'win.target.same' $target) }
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = 'VDI-ImageMaint'
        $result = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    } catch { Write-Log (T 'wu.searchError' $_.Exception.Message) ERR; return }

    if ($result.Updates.Count -eq 0) { Write-Log (T 'wu.none') OK; return }

    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    $skipped = 0
    foreach ($u in $result.Updates) {
        if ((Test-FeatureUpdate $u) -and -not ($allowFeature -and [string]$u.Title -match [regex]::Escape($target))) {
            Write-Log (T 'win.feature.skip' $u.Title); $skipped++
            continue
        }
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$coll.Add($u)
        Write-Log "  + $($u.Title)"
    }
    if ($skipped -and -not $allowFeature) { Write-Log (T 'win.feature.hint') WARN }
    if ($coll.Count -eq 0) { Write-Log (T 'wu.none') OK; return }
    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll
    Write-Log (T 'wu.downloading'); [void]$dl.Download()
    $ins = $session.CreateUpdateInstaller(); $ins.Updates = $coll
    Write-Log (T 'wu.installing'); $r = $ins.Install()

    $codes = @{ 0 = 'NotStarted'; 1 = 'InProgress'; 2 = 'Succeeded'; 3 = 'SucceededWithErrors'; 4 = 'Failed'; 5 = 'Aborted' }
    for ($i = 0; $i -lt $coll.Count; $i++) {
        $ur = $r.GetUpdateResult($i)
        if ($ur.ResultCode -ne 2) { Write-Log ("  ! {0}: {1} (HResult 0x{2:X8})" -f $coll.Item($i).Title, $codes[[int]$ur.ResultCode], $ur.HResult) WARN }
        Add-CycleItem -Kind Updates -Item @{ Title = [string]$coll.Item($i).Title; Result = $codes[[int]$ur.ResultCode] }
    }
    Write-Log (T 'wu.result' $codes[[int]$r.ResultCode] $r.RebootRequired) $(if ($r.ResultCode -in 2, 3) { 'OK' } else { 'WARN' })
}

function Invoke-Update {
    $issues = Invoke-Unlock
    if ($issues -gt 0 -and -not $isSystem) {
        # B7: protected services/tasks (WaaSMedicSvc, UsoSvc, UpdateOrchestrator) - Unlock again as SYSTEM
        Write-Log (T 'upd.unlockSystem') WARN
        $rc = Invoke-AsSystem -TargetMode 'Unlock'
        if ($rc -ne 0) { Write-Log (T 'upd.unlockSystemFailed' $rc) WARN }
    }
    if (-not $SkipOsot) { Invoke-OsotEnableUpdates }
    $before = @(Get-InstalledApps)

    Write-Log (T 'upd.infra') STEP
    Write-WindowsReleaseInfo
    $before | Where-Object { $_.Name -match $InfraPattern } | Sort-Object Name |
        ForEach-Object { Write-Log ("{0,-55} {1}" -f $_.Name, $_.Version) }

    if (-not $SkipPackages) {
        Invoke-PackagePlatform
        if ($script:PackageRunResult -eq 'reboot') { return }
    }
    if (-not $SkipWinget) { Install-WingetApps }
    Update-Defender
    if (-not $SkipOffice)        { Update-Office }
    if (-not $SkipVisualStudio)  { Update-VisualStudio }
    if (-not $SkipEdge)          { Update-Edge }
    if (-not $SkipTeams)         { Update-Teams }
    if (-not $SkipWinget)        { Update-WingetApps }
    if (-not $SkipWindowsUpdate) { Update-Windows }

    Show-AppDiff -Before $before -After @(Get-InstalledApps)

    $pending = @(Test-PendingReboot)
    $hard = @($pending | Where-Object { $_ -ne 'PendingFileRename' })
    if ($hard.Count -gt 0 -and $AutoReboot) {
        Write-Log (T 'upd.rebootNext' ($hard -join ', ')) WARN
        Request-RebootAndResume
    } elseif ($hard.Count -gt 0) {
        Write-Log (T 'upd.rebootRequired' ($hard -join ', ')) WARN
        if ($ThenSeal) { Write-Log (T 'upd.sealSkipped') WARN }
    } elseif ($ThenSeal) {
        # Day-2 cycle in one command: Update (with reboots) -> Seal as SYSTEM -> Finalize [-> shutdown]
        if ($pending.Count) { Write-Log (T 'upd.pendingFiles' ($pending -join ', ')) }
        Write-Log (T 'upd.thenSeal') STEP
        $rc = Invoke-SealAsSystemFlow
        if ($rc -ne 0) { throw (T 'upd.sealFailed' $rc) }
        $script:SealDone = $true
    } elseif ($pending.Count -gt 0) {
        Write-Log (T 'upd.rebootRequired' ($pending -join ', ')) WARN
    } else {
        Write-Log (T 'upd.noReboot') OK
    }
}
