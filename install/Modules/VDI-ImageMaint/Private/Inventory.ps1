# Inventory (packages + auto-update blocking status, CSV for Excel) and Status (report of the blocks).
# CSV columns and status values are language-neutral: Blocked | Active | NoUpdater | NotDetected.

function New-Status {
    param([object[]]$Checks, [string]$How)
    if (@($Checks | Where-Object { -not $_ }).Count -eq 0) { [pscustomobject]@{ Status = 'Blocked'; Detail = $How } }
    else { [pscustomobject]@{ Status = 'Active'; Detail = (T 'inv.partial' $How) } }
}

function New-NoUpdater { param([string]$How) [pscustomobject]@{ Status = 'NoUpdater'; Detail = $How } }

function Test-Policy { param([string]$Path, [string]$Name, $Value) return ((Get-RegValue $Path $Name) -eq $Value) }

function Test-SvcDisabled {
    param([string]$Pattern)
    foreach ($n in @($script:SvcNames | Where-Object { $_ -like $Pattern })) {
        if ((Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$n" 'Start') -ne 4) { return $false }
    }
    return $true
}

function Test-TasksDisabled {
    param([string]$Pattern)
    return (@($script:TaskCache | Where-Object { ($_.TaskPath + $_.TaskName) -like $Pattern -and $_.State -ne 'Disabled' }).Count -eq 0)
}

function Get-AppUpdateStatus {
    param($App, $Detected)
    foreach ($c in $UpdaterCatalog) { if ($App.Name -match $c.Match) { return (& $c.Check) } }
    $loc = ([string]$App.InstallLocation).TrimEnd('\')
    if ($loc.Length -gt 3) {
        $hit = @($Detected | Where-Object { ([string]$_.Detail).IndexOf($loc, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($hit.Count) { return [pscustomobject]@{ Status = 'Active'; Detail = (T 'inv.detected' (($hit | ForEach-Object { $_.Name }) -join ', ')) } }
    }
    return [pscustomobject]@{ Status = 'NotDetected'; Detail = '' }
}

function Export-WingetToLastInventory {
    $last = Get-ChildItem -Path (Join-Path $BaseDir 'Inventory') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { Export-WingetPackages -Dir $last.FullName }
}

function Invoke-Inventory {
    Write-Log (T 'inv.step') STEP
    $dir = Join-Path $BaseDir ('Inventory\{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $script:TaskCache = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
    $script:SvcNames  = @(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
    $detected = @(Find-UnmanagedUpdaters)

    $rows = @()
    foreach ($su in $SystemUpdaters) {
        $st = & $su.Check
        $rows += [pscustomobject]@{ Name = (T $su.Key); Version = ''; Publisher = 'Microsoft'; Type = 'System'; AutoUpdate = $st.Status; Details = $st.Detail; Location = '' }
    }
    foreach ($a in @(Get-InstalledApps | Sort-Object Name, Arch -Unique)) {
        $st = Get-AppUpdateStatus -App $a -Detected $detected
        $rows += [pscustomobject]@{ Name = $a.Name; Version = $a.Version; Publisher = $a.Publisher; Type = "Win32 $($a.Arch)"; AutoUpdate = $st.Status; Details = $st.Detail; Location = $a.InstallLocation }
    }
    $storeBlocked = Test-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2
    foreach ($px in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Sort-Object DisplayName)) {
        $ok = $storeBlocked
        $how = 'Store AutoDownload=2'
        if ($px.DisplayName -eq 'MSTeams') { $ok = $ok -and (Test-Policy 'HKLM:\SOFTWARE\Microsoft\Teams' 'disableAutoUpdate' 1); $how += ' + Teams disableAutoUpdate=1' }
        $rows += [pscustomobject]@{
            Name = $px.DisplayName; Version = [string]$px.Version; Publisher = ''; Type = 'MSIX provisioned'
            AutoUpdate = $(if ($ok) { 'Blocked' } else { 'Active' }); Details = $how; Location = ''
        }
    }

    $csv = Join-Path $dir 'packages.csv'
    $rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    $detected | Select-Object Type, Name, Detail | Export-Csv -Path (Join-Path $dir 'detected-updaters.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    if (-not $isSystem) { Export-WingetPackages -Dir $dir }
    else { Write-Log (T 'inv.wingetLater') }

    Write-Log (T 'inv.summary') STEP
    $rows | Group-Object AutoUpdate | Sort-Object Name | ForEach-Object { Write-Log ("{0,-24} {1}" -f (T "inv.status.$($_.Name)"), $_.Count) }
    $act = @($rows | Where-Object { $_.AutoUpdate -eq 'Active' })
    if ($act.Count) {
        Write-Log (T 'inv.active') WARN
        $act | Format-Table Name, Version, Type, Details -AutoSize | Out-String -Width 250 | Write-Host
    } else {
        Write-Log (T 'inv.allBlocked') OK
    }
    Write-Log (T 'inv.report' $csv) OK
}

function Show-Status {
    Write-Log (T 'status.step') STEP
    $startNames = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
    $rows = foreach ($s in @(Resolve-ServiceDefs)) {
        $reg = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)"
        if (-not (Test-Path $reg)) { continue }
        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Service = $s.Name
            Start   = $startNames[[int](Get-RegValue $reg 'Start')]
            State   = $(if ($svc) { $svc.Status } else { '?' })
        }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host

    $rows = foreach ($p in $PolicyDefs) {
        $cur = Get-RegValue $p.Path $p.Name
        [pscustomobject]@{
            Policy  = $p.Name
            Seal    = $p.Value
            Current = $(if ($null -eq $cur) { T 'status.none' } else { $cur })
            OK      = $(if ($cur -eq $p.Value) { T 'status.yes' } else { '-' })
        }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host

    $tasks  = @(Get-MatchingTasks)
    $active = @($tasks | Where-Object { $_.State -ne 'Disabled' })
    Write-Log (T 'status.tasks' $tasks.Count $active.Count) $(if ($active.Count) { 'WARN' } else { 'OK' })
    foreach ($t in $active) { Write-Log (T 'status.taskActive' "$($t.TaskPath)$($t.TaskName)") }

    foreach ($f in $FileDefs) {
        if (Test-Path $f)                { Write-Log (T 'status.fileActive' $f) WARN }
        elseif (Test-Path "$f.disabled") { Write-Log (T 'seal.file.disabled' $f) OK }
    }

    $m365 = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'VersionToReport'
    if ($m365) { Write-Log (T 'status.m365' $m365) }

    $pending = @(Test-PendingReboot)
    if ($pending.Count) { Write-Log (T 'status.pending' ($pending -join ', ')) WARN } else { Write-Log (T 'status.noPending') OK }

    $st = Get-SealState
    if ($st -and $st.Sealed) { Write-Log (T 'status.sealed' $st.Created) OK }
    elseif ($st) { Write-Log (T 'status.baseline' $st.Created) WARN }
    else { Write-Log (T 'status.notSealed') WARN }
}
