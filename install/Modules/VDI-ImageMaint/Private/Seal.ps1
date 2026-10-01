# Seal (block automatic updates) and Unlock (restore exactly what Seal changed).
# Every change is recorded in seal-state.json; records are never overwritten, so the first recorded value
# is always the original one.

# ---------- seal state ----------
function New-SealState {
    [ordered]@{
        Created  = (Get-Date).ToString('s')
        Computer = $env:COMPUTERNAME
        Sealed   = $false   # false = only the baseline recorded before OSOT (Seal not finished)
        Services = @()
        Tasks    = @()
        Registry = @()
        Files    = @()
    }
}

function Get-SealState {
    if (-not (Test-Path $StateFile)) { return $null }
    $j = Get-Content -Path $StateFile -Raw | ConvertFrom-Json
    $s = New-SealState
    $s.Created  = $j.Created
    $s.Computer = $j.Computer
    $s.Sealed   = [bool](Get-PV $j 'Sealed' $true)   # files written before 1.8.0 have no field = sealed
    foreach ($k in 'Services', 'Tasks', 'Registry', 'Files') { $s[$k] = @(Get-PV $j $k @() | Where-Object { $_ }) }
    return $s
}

function Save-SealState {
    param($State)
    $State | ConvertTo-Json -Depth 6 | Set-Content -Path $StateFile -Encoding UTF8
}

# ---------- baseline ----------
# Recorded BEFORE OSOT: OSOT -windowsupdate disable itself disables services and sets policies; if the state
# were recorded after OSOT, Unlock would "restore" disabled services.
function Add-PolicyBaseline {
    param($Def, $State)
    if (@($State.Registry | Where-Object { $_.Path -eq $Def.Path -and $_.Name -eq $Def.Name }).Count) { return }
    $rec = [pscustomobject]@{ Path = $Def.Path; Name = $Def.Name; Existed = $false; OldValue = $null; OldKind = $null }
    $key = Get-Item -LiteralPath $Def.Path -ErrorAction SilentlyContinue
    if ($key -and ($key.GetValueNames() -contains $Def.Name)) {
        $rec.Existed  = $true
        $rec.OldValue = $key.GetValue($Def.Name, $null, 'DoNotExpandEnvironmentNames')
        $rec.OldKind  = $key.GetValueKind($Def.Name).ToString()
    }
    $State.Registry += $rec
}

function Add-ServiceBaseline {
    param([string]$Name, $State)
    $reg = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path $reg)) { return }
    if (@($State.Services | Where-Object { $_.Name -eq $Name }).Count) { return }
    $State.Services += [pscustomobject]@{ Name = $Name; Start = [int](Get-RegValue $reg 'Start') }
}

function Add-TaskBaseline {
    param($Task, $State)
    $full = $Task.TaskPath + $Task.TaskName
    if (@($State.Tasks | Where-Object { $_.FullName -eq $full }).Count) { return }
    $State.Tasks += [pscustomobject]@{
        TaskPath = $Task.TaskPath; TaskName = $Task.TaskName; FullName = $full
        WasEnabled = ($Task.State -ne 'Disabled')
    }
}

function Save-SealBaseline {
    $state = Get-SealState
    if (-not $state) { $state = New-SealState }
    foreach ($p in $PolicyDefs) { Add-PolicyBaseline -Def $p -State $state }
    foreach ($s in @(Resolve-ServiceDefs)) { Add-ServiceBaseline -Name $s.Name -State $state }
    foreach ($t in @(Get-MatchingTasks)) { Add-TaskBaseline -Task $t -State $state }
    Save-SealState -State $state
    Write-Log (T 'seal.baseline' $StateFile)
}

# ---------- seal elements ----------
function Set-PolicyValue {
    param($Def, $State)
    Add-PolicyBaseline -Def $Def -State $State
    if (-not (Test-Path $Def.Path)) { New-Item -Path $Def.Path -Force | Out-Null }
    $type = if ($Def.ContainsKey('Type')) { $Def.Type } else { 'DWord' }
    New-ItemProperty -Path $Def.Path -Name $Def.Name -Value $Def.Value -PropertyType $type -Force | Out-Null
    Write-Log (T 'seal.policy' ($Def.Path -replace '^HKLM:\\SOFTWARE\\Policies\\', '') $Def.Name $Def.Value) OK
}

function Disable-UpdateService {
    param($Def, $State)
    $reg = "HKLM:\SYSTEM\CurrentControlSet\Services\$($Def.Name)"
    if (-not (Test-Path $reg)) { Write-Log (T 'seal.svc.missing' $Def.Name); return }
    $cur = [int](Get-RegValue $reg 'Start')
    Add-ServiceBaseline -Name $Def.Name -State $State
    try {
        Set-ItemProperty -Path $reg -Name Start -Value 4 -ErrorAction Stop
        Write-Log (T 'seal.svc.disabled' $Def.Name $cur) OK
    } catch {
        Write-Log (T 'seal.svc.protected' $Def.Name) WARN
        $script:SealIssues++
    }
    try { Stop-Service -Name $Def.Name -Force -ErrorAction Stop -WarningAction SilentlyContinue }
    catch { Write-Log (T 'seal.svc.stopFailed' $Def.Name $_.Exception.Message) WARN }
}

function Disable-OneTask {
    param($Task, $State)
    $full = $Task.TaskPath + $Task.TaskName
    Add-TaskBaseline -Task $Task -State $State
    if ($Task.State -eq 'Disabled') { return }
    try {
        Disable-ScheduledTask -TaskPath $Task.TaskPath -TaskName $Task.TaskName -ErrorAction Stop | Out-Null
        Write-Log (T 'seal.task.disabled' $full) OK
    } catch {
        Write-Log (T 'seal.task.protected' $full) WARN
        $script:SealIssues++
    }
}

function Disable-UpdateTasks {
    param($State)
    foreach ($t in @(Get-MatchingTasks)) { Disable-OneTask -Task $t -State $State }
}

function Find-UnmanagedUpdaters {
    # Active third-party tasks and services that look like updaters and are not covered by the fixed lists
    # Type: Task | Service
    $found = @()
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        if ($t.State -eq 'Disabled') { continue }
        $full = $t.TaskPath + $t.TaskName
        if ($full -like '\Microsoft\Windows\*') { continue }
        if (@($TaskPatterns | Where-Object { $full -like $_ }).Count) { continue }
        $exec = @($t.Actions | ForEach-Object {
            if ($_.PSObject.Properties['Execute'] -and $_.Execute) { ("{0} {1}" -f $_.Execute, $_.Arguments).Trim() }
        }) -join ' | '
        $text = "$full $exec"
        if ($text -notmatch $UpdaterDetectPattern -or $text -match $DetectExcludePattern) { continue }
        $found += [pscustomobject]@{ Type = 'Task'; Name = $full; Detail = $exec; Task = $t }
    }
    $managed = @(Resolve-ServiceDefs | ForEach-Object { $_.Name })
    foreach ($svc in @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)) {
        if ($svc.StartMode -eq 'Disabled' -or $managed -contains $svc.Name) { continue }
        $path = [string]$svc.PathName
        if ($path -match '\\Windows\\') { continue }   # system services
        $text = "$($svc.Name) $($svc.DisplayName) $path"
        if ($text -notmatch $UpdaterDetectPattern -or $text -match $DetectExcludePattern) { continue }
        $found += [pscustomobject]@{ Type = 'Service'; Name = $svc.Name; Detail = $path; Task = $null }
    }
    return $found
}

function Disable-DetectedUpdaters {
    param($State)
    $found = @(Find-UnmanagedUpdaters)
    if ($found.Count -eq 0) { Write-Log (T 'seal.detect.none') OK; return }
    foreach ($f in $found) {
        $type = T "seal.type.$($f.Type)"
        if ($NoBlockDetected) { Write-Log (T 'seal.detect.reportOnly' $type $f.Name $f.Detail) WARN; continue }
        Write-Log (T 'seal.detect.found' $type $f.Name $f.Detail)
        if ($f.Type -eq 'Task') { Disable-OneTask -Task $f.Task -State $State }
        else { Disable-UpdateService -Def @{ Name = $f.Name; Default = 3 } -State $State }
    }
}

function Disable-UpdaterFiles {
    param($State)
    foreach ($f in $FileDefs) {
        if (-not (Test-Path $f)) { continue }
        $dst = "$f.disabled"
        if (Test-Path $dst) { Remove-Item $dst -Force }
        Rename-Item -Path $f -NewName (Split-Path $dst -Leaf) -Force
        if (@($State.Files | Where-Object { $_.Path -eq $f }).Count -eq 0) {
            $State.Files += [pscustomobject]@{ Path = $f }
        }
        Write-Log (T 'seal.file.disabled' $f) OK
    }
}

function Invoke-ImageCleanup {
    Write-Log (T 'cleanup.step') STEP
    Stop-Service -Name wuauserv, BITS -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log (T 'cleanup.sd') OK
    try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null; Write-Log (T 'cleanup.do') OK }
    catch { Write-Log (T 'cleanup.doSkipped') }
    Remove-Item "$env:ProgramFiles\Microsoft Office\Updates\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log (T 'cleanup.temp') OK
    Write-Log (T 'cleanup.dism')
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null
    Write-Log (T 'cleanup.dismDone' $LASTEXITCODE) $(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'WARN' })
}

function Assert-SealPreconditions {
    # B6: checked BEFORE OSOT (also in the -AsSystem parent) so an image is not optimized when Seal
    # would reject it anyway
    $pending = @(Test-PendingReboot)
    $hard = @($pending | Where-Object { $_ -ne 'PendingFileRename' })
    if ($hard.Count -gt 0 -and -not $Force) { throw (T 'seal.pendingReboot' ($hard -join ', ')) }
    if ($pending.Count -gt 0) { Write-Log (T 'seal.pendingWarn' ($pending -join ', ')) WARN }
}

function Invoke-Seal {
    Write-Log (T 'seal.step') STEP
    Assert-SealPreconditions
    if (-not $SkipOsot -and -not $isSystem) { Save-SealBaseline; Invoke-OsotSealPre }

    $state = Get-SealState
    if ($state -and $state.Sealed) { Write-Log (T 'seal.already' $state.Created) }
    elseif ($state) { Write-Log (T 'seal.fromBaseline' $state.Created) }
    else            { $state = New-SealState }

    $script:SealIssues = 0
    try {
        Write-Log (T 'seal.sec.policies') STEP
        foreach ($p in $PolicyDefs)  { Set-PolicyValue -Def $p -State $state }
        Write-Log (T 'seal.sec.services') STEP
        foreach ($s in @(Resolve-ServiceDefs)) { Disable-UpdateService -Def $s -State $state }
        Write-Log (T 'seal.sec.tasks') STEP
        Disable-UpdateTasks -State $state
        Write-Log (T 'seal.sec.files') STEP
        Disable-UpdaterFiles -State $state
        Write-Log (T 'seal.sec.detect') STEP
        Disable-DetectedUpdaters -State $state
        $state.Sealed = $true
    } finally {
        Save-SealState -State $state
        Write-Log (T 'seal.stateSaved' $StateFile)
    }

    if ($Cleanup) { Invoke-ImageCleanup }
    Show-Status
    Invoke-Inventory
    if (-not $SkipOsot -and -not $isSystem) { Invoke-OsotFinalize }

    if ($script:SealIssues -gt 0) { Write-Log (T 'seal.doneWarn' $script:SealIssues) WARN }
    else { Write-Log (T 'seal.done') OK }
    Write-Log (T 'seal.next') STEP
}

function Invoke-SealAsSystemFlow {
    # Seal from the admin account: baseline + OSOT Optimize (admin) -> blocking as SYSTEM -> winget export -> OSOT Finalize (admin)
    Assert-SealPreconditions
    if (-not $SkipOsot) { Save-SealBaseline; Invoke-OsotSealPre }
    $rc = Invoke-AsSystem -TargetMode 'Seal'
    Export-WingetToLastInventory
    if ($rc -eq 0 -and -not $SkipOsot) { Invoke-OsotFinalize }
    return $rc
}

# ---------- unlock ----------
function Invoke-Unlock {
    # Returns the number of items that could not be restored (B7: Update retries them as SYSTEM)
    Write-Log (T 'unlock.step') STEP
    $state  = Get-SealState
    $issues = 0

    if (-not $state) {
        Write-Log (T 'unlock.noState') WARN
        foreach ($p in $PolicyDefs) {
            if ((Get-RegValue $p.Path $p.Name) -eq $p.Value) {
                Remove-ItemProperty -Path $p.Path -Name $p.Name -ErrorAction SilentlyContinue
                Write-Log (T 'unlock.policyRemoved' $p.Name) OK
            }
        }
        foreach ($s in @(Resolve-ServiceDefs)) {
            $reg = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)"
            if ((Test-Path $reg) -and (Get-RegValue $reg 'Start') -eq 4) {
                try { Set-ItemProperty -Path $reg -Name Start -Value $s.Default -ErrorAction Stop; Write-Log (T 'unlock.svc' $s.Name $s.Default) OK }
                catch { Write-Log (T 'unlock.svcDenied' $s.Name) WARN }
            }
        }
        foreach ($f in $FileDefs) {
            if ((Test-Path "$f.disabled") -and -not (Test-Path $f)) { Rename-Item "$f.disabled" -NewName (Split-Path $f -Leaf); Write-Log (T 'unlock.file' $f) OK }
        }
        Write-Log (T 'unlock.tasksUnknown') WARN
        return 0
    }

    foreach ($r in $state.Registry) {
        try {
            if ($r.Existed) {
                if (-not (Test-Path $r.Path)) { New-Item -Path $r.Path -Force | Out-Null }
                New-ItemProperty -Path $r.Path -Name $r.Name -Value $r.OldValue -PropertyType $r.OldKind -Force | Out-Null
            } else {
                Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue
            }
            Write-Log (T 'unlock.policy' $r.Name) OK
        } catch { Write-Log (T 'unlock.policyFailed' $r.Name $_.Exception.Message) WARN; $issues++ }
    }
    foreach ($s in $state.Services) {
        $reg = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)"
        if (-not (Test-Path $reg)) { continue }
        try { Set-ItemProperty -Path $reg -Name Start -Value ([int]$s.Start) -ErrorAction Stop; Write-Log (T 'unlock.svc' $s.Name $s.Start) OK }
        catch { Write-Log (T 'unlock.svcDenied' $s.Name) WARN; $issues++ }
    }
    foreach ($t in $state.Tasks) {
        if (-not $t.WasEnabled) { continue }
        try { Enable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null; Write-Log (T 'unlock.task' $t.FullName) OK }
        catch {
            if (Get-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction SilentlyContinue) {
                Write-Log (T 'unlock.taskDenied' $t.FullName) WARN; $issues++
            }
        }
    }
    foreach ($f in $state.Files) {
        if ((Test-Path "$($f.Path).disabled") -and -not (Test-Path $f.Path)) {
            Rename-Item "$($f.Path).disabled" -NewName (Split-Path $f.Path -Leaf); Write-Log (T 'unlock.file' $f.Path) OK
        }
    }

    if ($issues -eq 0) { Remove-Item $StateFile -Force; Write-Log (T 'unlock.done') OK }
    else { Write-Log (T 'unlock.partial' $issues) WARN }
    return $issues
}
