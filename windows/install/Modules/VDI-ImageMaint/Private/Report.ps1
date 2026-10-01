# Cycle journal and HTML report.
# A cycle = everything from the first changing run (Update, Packages, Optimize, Generalize, ...) to the Seal that
# closes it. Every run (also after reboots and the SYSTEM child processes) adds itself to cycle.json, keyed by its
# own Id, so parallel writers never overwrite each other. Seal (or -Mode Report) writes a self-contained HTML page.

$script:CycleFile  = Join-Path $BaseDir 'cycle.json'
$script:ReportDir  = Join-Path $BaseDir 'Reports'
$script:CycleModes = @('Update', 'Packages', 'Optimize', 'Finalize', 'Seal', 'Generalize', 'PostGeneralize', 'Unlock')
$script:Cycle      = $null
$script:CycleRun   = $null
$script:MaxRunEvents = 3000

function Read-Cycle {
    param([string]$Path = $script:CycleFile)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-CycleRun {
    # Merges the current run into cycle.json on disk (no Write-Log here: Write-Log calls Add-CycleEvent)
    param([switch]$Close)
    if (-not $script:Cycle -or -not $script:CycleRun) { return }
    $disk = Read-Cycle
    $c = $(if ($disk -and $disk.Id -eq $script:Cycle.Id) { $disk } else { $script:Cycle })
    # replace this run in place or append it - keeps the order of the runs (Sort-Object is not stable in PS 5.1)
    $me = [pscustomobject]$script:CycleRun
    $runs = @(@($c.Runs) | Where-Object { $_ } | ForEach-Object { if ($_.Id -eq $me.Id) { $me } else { $_ } })
    if (-not @($runs | Where-Object { $_.Id -eq $me.Id }).Count) { $runs += $me }
    $c.Runs = $runs
    if ($Close) { $c.Closed = (Get-Date).ToString('s') }
    $null = New-Item -ItemType Directory -Path (Split-Path $script:CycleFile -Parent) -Force
    $tmp = "$($script:CycleFile).tmp"
    [IO.File]::WriteAllText($tmp, ($c | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $script:CycleFile -Force
    $script:Cycle = $c
}

function Start-CycleRun {
    # Opens (or continues) the cycle for a changing mode; other modes do not touch the journal
    param([string]$RunMode)
    $script:Cycle = $null; $script:CycleRun = $null
    if ($script:CycleModes -notcontains $RunMode) { return }
    $c = Read-Cycle
    if (-not $c -or $c.Closed) {
        $rel = Get-WindowsRelease
        $c = [pscustomobject]@{
            Id = (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 4); Started = (Get-Date).ToString('s'); Computer = $env:COMPUTERNAME
            ToolVersion = $script:ToolVersion; WindowsBefore = "$($rel.Release) $($rel.Build).$($rel.UBR)"
            AppsBefore = @(Get-InstalledApps | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = $_.Version } })
            Closed = $null; Runs = @()
        }
    }
    $script:Cycle = $c
    $script:CycleRun = [ordered]@{
        Id = [guid]::NewGuid().ToString('N'); Mode = $RunMode; Started = (Get-Date).ToString('s'); Ended = $null; ExitCode = $null
        User = [Security.Principal.WindowsIdentity]::GetCurrent().Name; Events = @(); Updates = @(); Packages = @()
    }
    Save-CycleRun
}

function Add-CycleEvent {
    param([string]$Level, [string]$Message)
    if (-not $script:CycleRun) { return }
    if (@($script:CycleRun.Events).Count -ge $script:MaxRunEvents) { return }
    $script:CycleRun.Events = @($script:CycleRun.Events) + [pscustomobject]@{ T = (Get-Date -Format 'HH:mm:ss'); L = $Level; M = $Message }
    # flush on steps and errors: a reboot or a crash keeps everything up to here
    if ($Level -in 'STEP', 'ERR') { try { Save-CycleRun } catch { Write-Verbose $_.Exception.Message } }
}

function Add-CycleItem {
    # Kind: Updates (Title, Result) | Packages (Id, Name, From, To, Result)
    param([ValidateSet('Updates', 'Packages')][string]$Kind, [hashtable]$Item)
    if (-not $script:CycleRun) { return }
    $script:CycleRun[$Kind] = @($script:CycleRun[$Kind]) + [pscustomobject]$Item
}

function Stop-CycleRun {
    # Ends the run; -Close ends the cycle and writes the report. Returns the report path or ''.
    param([int]$ExitCode, [switch]$Close)
    if (-not $script:CycleRun) { return '' }
    $script:CycleRun.Ended = (Get-Date).ToString('s'); $script:CycleRun.ExitCode = $ExitCode
    Save-CycleRun -Close:$Close
    $path = ''
    if ($Close) {
        $path = New-CycleReport -Cycle $script:Cycle
        $null = New-Item -ItemType Directory -Path $script:ReportDir -Force
        Copy-Item -LiteralPath $script:CycleFile -Destination (Join-Path $script:ReportDir "cycle_$($script:Cycle.Id).json") -Force
    }
    $script:CycleRun = $null
    return $path
}

function Get-AppDiff {
    # Kind: new | updated | removed
    param($Before, $After)
    $b = @{}; foreach ($x in @($Before)) { if ($x) { $b[$x.Name] = [string]$x.Version } }
    $a = @{}; foreach ($x in @($After))  { if ($x) { $a[$x.Name] = [string]$x.Version } }
    $out = @()
    foreach ($k in $a.Keys) {
        if (-not $b.ContainsKey($k)) { $out += [pscustomobject]@{ App = $k; Before = ''; After = $a[$k]; Kind = 'new' } }
        elseif ($b[$k] -ne $a[$k])   { $out += [pscustomobject]@{ App = $k; Before = $b[$k]; After = $a[$k]; Kind = 'updated' } }
    }
    foreach ($k in $b.Keys) { if (-not $a.ContainsKey($k)) { $out += [pscustomobject]@{ App = $k; Before = $b[$k]; After = ''; Kind = 'removed' } } }
    return @($out | Sort-Object App)
}

# ---------- HTML ----------
function Format-ReportTime {
    # cycle.json keeps ISO text; pwsh 7 ConvertFrom-Json turns it into DateTime
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss') }
    return ([string]$Value).Replace('T', ' ')
}

function New-ReportCard {
    param([string]$Title, [string]$Value, [string]$Sub, [string]$Class = '')
    return "<div class=""card $Class""><div class=""ct"">$(ConvertTo-HtmlText $Title)</div><div class=""cv"">$(ConvertTo-HtmlText $Value)</div><div class=""cs"">$(ConvertTo-HtmlText $Sub)</div></div>"
}
function ConvertTo-HtmlText { param($Text) return [System.Net.WebUtility]::HtmlEncode([string]$Text) }

function New-HtmlTable {
    # Rows: objects; Columns: ordered @{ Header = 'Property' }; optional per-row CSS class from $RowClass
    param([object[]]$Rows, [System.Collections.Specialized.OrderedDictionary]$Columns, [scriptblock]$RowClass, [string]$Empty)
    if (@($Rows).Count -eq 0) { return "<p class=""muted"">$(ConvertTo-HtmlText $Empty)</p>" }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('<table><thead><tr>')
    foreach ($h in $Columns.Keys) { [void]$sb.Append("<th>$(ConvertTo-HtmlText $h)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in @($Rows)) {
        $cls = $(if ($RowClass) { [string](& $RowClass $r) } else { '' })
        [void]$sb.Append($(if ($cls) { "<tr class=""$cls"">" } else { '<tr>' }))
        foreach ($h in $Columns.Keys) { [void]$sb.Append("<td>$(ConvertTo-HtmlText (Get-PV $r $Columns[$h] ''))</td>") }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function Get-ReportFacts {
    # Live facts of the machine for the report (each part may fail without a full admin context)
    $rel = Get-WindowsRelease
    $apps = @(Get-InstalledApps)
    $agent = @($apps | Where-Object { $_.Name -match 'Horizon Agent$' }) | Select-Object -First 1
    $infra = @($apps | Where-Object { $_.Name -match $InfraPattern } | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = $_.Version } })
    $office = [string](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'VersionToReport')
    if ($office) { $infra += [pscustomobject]@{ Name = 'Microsoft 365 Apps'; Version = $office } }
    try {
        $teams = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object DisplayName -eq 'MSTeams') | Select-Object -First 1
        if ($teams) { $infra += [pscustomobject]@{ Name = 'Microsoft Teams (provisioned)'; Version = $teams.Version } }
    } catch { Write-Verbose $_.Exception.Message }
    $state = Get-SealState
    $svc = @(foreach ($s in @(Resolve-ServiceDefs)) {
        $start = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)" 'Start'
        [pscustomobject]@{ Name = $s.Name; Start = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }[[int]$start] }
    })
    $tasks = @(); try { $tasks = @(Get-MatchingTasks | Where-Object { $_.State -ne 'Disabled' }) } catch { Write-Verbose $_.Exception.Message }
    $pol = @($PolicyDefs | Where-Object { (Get-RegValue $_.Path $_.Name) -eq $_.Value })
    return [pscustomobject]@{
        Release = $rel; Apps = $apps; AgentVersion = $(if ($agent) { [string]$agent.Version } else { '' }); Infra = $infra
        Sealed = [bool](Get-PV $state 'Sealed' $false); SealCreated = [string](Get-PV $state 'Created' '')
        Services = $svc; ActiveTasks = $tasks.Count; PoliciesSet = $pol.Count; PoliciesAll = @($PolicyDefs).Count
        Pending = @(Test-PendingReboot)
    }
}

function New-CycleReport {
    # Writes Reports\VDI-ImageMaint_<computer>_<cycle>.html and returns its path
    param($Cycle, $Facts = (Get-ReportFacts), [string]$OutDir = $script:ReportDir)
    $runs = @($Cycle.Runs | Where-Object { $_ })
    $events = @(foreach ($r in $runs) { foreach ($e in @($r.Events)) { if ($e) { [pscustomobject]@{ Run = $r.Mode; T = $e.T; L = $e.L; M = $e.M } } } })
    $errs  = @($events | Where-Object L -eq 'ERR')
    $warns = @($events | Where-Object L -eq 'WARN')
    $failedRuns = @($runs | Where-Object { $null -ne $_.ExitCode -and [int]$_.ExitCode -ne 0 })
    $updates  = @(foreach ($r in $runs) { @($r.Updates) | Where-Object { $_ } })
    $packages = @(foreach ($r in $runs) { @($r.Packages) | Where-Object { $_ } })
    $diff = @(Get-AppDiff -Before @($Cycle.AppsBefore) -After $Facts.Apps)
    $rel = $Facts.Release

    $status = $(if ($errs.Count -or $failedRuns.Count) { 'err' } elseif ($warns.Count) { 'warn' } else { 'ok' })
    $statusText = T "rep.status.$status"
    $hz = Get-HorizonAgentSupportText -AgentVersion (Get-HorizonAgentVersion $Facts.AgentVersion) -Release $rel
    $end = $(if ($rel.Info) { $(if ($rel.Edition -match '^(Enterprise|Education)') { $rel.Info.EndEntEdu } else { $rel.Info.EndPro }) } else { '-' })
    $period = "$(Format-ReportTime $Cycle.Started) → $(if ($Cycle.Closed) { Format-ReportTime $Cycle.Closed } else { T 'rep.open' })"
    $winAfter = "$($rel.Release) $($rel.Build).$($rel.UBR)"
    $okPk = @($packages | Where-Object { $_.Result -ne 'failed' }).Count
    $upOk = @($updates | Where-Object { $_.Result -in 'Succeeded', 'SucceededWithErrors' }).Count

    $cards = @(
        (New-ReportCard (T 'rep.card.windows') $winAfter ((T 'rep.card.windowsSub' $Cycle.WindowsBefore $end)))
        (New-ReportCard 'Horizon Agent' $(if ($Facts.AgentVersion) { "$(Get-HorizonMarketingName (Get-HorizonAgentVersion $Facts.AgentVersion)) ($($Facts.AgentVersion))" } else { T 'rep.none' }) $(if ($hz) { $hz } else { T 'rep.card.supported' }) $(if ($hz) { 'warn' } else { '' }))
        (New-ReportCard (T 'rep.card.changes') ([string]$diff.Count) (T 'rep.card.changesSub' $upOk $updates.Count $okPk $packages.Count))
        (New-ReportCard (T 'rep.card.problems') "$($errs.Count) / $($warns.Count)" (T 'rep.card.problemsSub') $(if ($errs.Count) { 'err' } elseif ($warns.Count) { 'warn' } else { 'ok' }))
        (New-ReportCard 'Seal' $(if ($Facts.Sealed) { T 'rep.sealed' } else { T 'rep.notSealed' }) (T 'rep.card.sealSub' $Facts.PoliciesSet $Facts.PoliciesAll $Facts.ActiveTasks) $(if ($Facts.Sealed -and -not $Facts.ActiveTasks) { 'ok' } else { 'warn' }))
    ) -join ''

    $kindText = @{ new = (T 'rep.kind.new'); updated = (T 'rep.kind.updated'); removed = (T 'rep.kind.removed') }
    $diffRows = @($diff | ForEach-Object { [pscustomobject]@{ App = $_.App; Before = $_.Before; After = $_.After; Kind = $kindText[$_.Kind]; K = $_.Kind } })
    $colDiff = [ordered]@{}; $colDiff[(T 'rep.col.app')] = 'App'; $colDiff[(T 'rep.col.change')] = 'Kind'; $colDiff[(T 'rep.col.before')] = 'Before'; $colDiff[(T 'rep.col.after')] = 'After'
    $colUpd = [ordered]@{}; $colUpd[(T 'rep.col.update')] = 'Title'; $colUpd[(T 'rep.col.result')] = 'Result'
    $colPkg = [ordered]@{}; $colPkg['Id'] = 'Id'; $colPkg[(T 'rep.col.app')] = 'Name'; $colPkg[(T 'rep.col.before')] = 'From'; $colPkg[(T 'rep.col.after')] = 'To'; $colPkg[(T 'rep.col.result')] = 'Result'
    $colInfra = [ordered]@{}; $colInfra[(T 'rep.col.component')] = 'Name'; $colInfra[(T 'rep.col.version')] = 'Version'
    $colSvc = [ordered]@{}; $colSvc[(T 'rep.col.service')] = 'Name'; $colSvc[(T 'rep.col.startType')] = 'Start'
    $colEv = [ordered]@{}; $colEv[(T 'rep.col.run')] = 'Run'; $colEv[(T 'rep.col.time')] = 'T'; $colEv[(T 'rep.col.level')] = 'L'; $colEv[(T 'rep.col.message')] = 'M'
    $colRun = [ordered]@{}; $colRun[(T 'rep.col.run')] = 'Mode'; $colRun[(T 'rep.col.user')] = 'User'; $colRun[(T 'rep.col.start')] = 'Start'; $colRun[(T 'rep.col.end')] = 'End'; $colRun[(T 'rep.col.exit')] = 'Exit'
    $runRows = @($runs | ForEach-Object {
        [pscustomobject]@{ Mode = $_.Mode; User = $_.User; Start = (Format-ReportTime $_.Started); End = $(if ($_.Ended) { Format-ReportTime $_.Ended } else { T 'rep.running' }); Exit = $(if ($null -ne $_.ExitCode) { $_.ExitCode } else { '-' }) }
    })
    $levelCls = { param($r) switch ($r.L) { 'ERR' { 'err' } 'WARN' { 'warn' } 'OK' { 'ok' } 'STEP' { 'step' } default { '' } } }

    $runLogs = (@(foreach ($r in $runs) {
        $evRows = @(@($r.Events) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Run = $r.Mode; T = $_.T; L = $_.L; M = $_.M } })
        "<details><summary>$(ConvertTo-HtmlText "$($r.Mode) - $(Format-ReportTime $r.Started) - $($r.User)") ($($evRows.Count))</summary>" +
            (New-HtmlTable -Rows $evRows -Columns $colEv -RowClass $levelCls -Empty (T 'rep.none')) + '</details>'
    })) -join "`n"

    $pending = $(if ($Facts.Pending.Count) { "<p class=""warnbox"">$(ConvertTo-HtmlText (T 'rep.pending' ($Facts.Pending -join ', ')))</p>" } else { '' })
    $html = @"
<!DOCTYPE html>
<html lang="$(if ($script:UICultureName -eq 'pl-PL') { 'pl' } else { 'en' })">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(ConvertTo-HtmlText (T 'rep.title')) - $(ConvertTo-HtmlText $Cycle.Computer)</title>
<style>
:root { --bg:#f6f7f9; --fg:#1d2330; --muted:#667085; --card:#fff; --line:#e3e6eb; --ok:#127a3a; --okbg:#e7f6ec; --warn:#8a5a00; --warnbg:#fff4d6; --err:#b42318; --errbg:#fde8e7; --acc:#1f5fbf; }
@media (prefers-color-scheme: dark) { :root { --bg:#14171c; --fg:#e6e8eb; --muted:#9aa3af; --card:#1d2128; --line:#2c323b; --ok:#5fd28a; --okbg:#173323; --warn:#f2c14e; --warnbg:#3a2f12; --err:#ff8a80; --errbg:#3d1c1a; --acc:#7aa7ff; } }
* { box-sizing: border-box; }
body { margin:0; padding:24px 16px; background:var(--bg); color:var(--fg); font:14px/1.45 "Segoe UI", system-ui, sans-serif; }
main { max-width:1200px; margin:0 auto; }
h1 { font-size:22px; margin:0 0 4px; } h2 { font-size:17px; margin:28px 0 10px; border-bottom:1px solid var(--line); padding-bottom:4px; }
.meta { color:var(--muted); margin-bottom:16px; }
.badge { display:inline-block; padding:3px 10px; border-radius:999px; font-weight:600; font-size:13px; }
.badge.ok { color:var(--ok); background:var(--okbg); } .badge.warn { color:var(--warn); background:var(--warnbg); } .badge.err { color:var(--err); background:var(--errbg); }
.cards { display:grid; grid-template-columns:repeat(auto-fit, minmax(200px, 1fr)); gap:12px; }
.card { background:var(--card); border:1px solid var(--line); border-left:4px solid var(--acc); border-radius:8px; padding:12px; }
.card.ok { border-left-color:var(--ok); } .card.warn { border-left-color:var(--warn); } .card.err { border-left-color:var(--err); }
.ct { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.04em; } .cv { font-size:18px; font-weight:600; margin:4px 0; word-break:break-word; } .cs { color:var(--muted); font-size:12px; }
.scroll { overflow-x:auto; }
table { width:100%; border-collapse:collapse; background:var(--card); border:1px solid var(--line); border-radius:8px; }
th, td { text-align:left; padding:6px 10px; border-bottom:1px solid var(--line); vertical-align:top; word-break:break-word; }
th { font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:.03em; }
tr.err td { background:var(--errbg); } tr.warn td { background:var(--warnbg); } tr.ok td:nth-child(3) { color:var(--ok); } tr.step td { font-weight:600; }
tr.new td:nth-child(2) { color:var(--ok); } tr.removed td:nth-child(2) { color:var(--err); } tr.updated td:nth-child(2) { color:var(--acc); }
.muted { color:var(--muted); } .warnbox { background:var(--warnbg); color:var(--warn); padding:8px 12px; border-radius:6px; }
details { margin:6px 0; } summary { cursor:pointer; padding:6px 0; }
footer { margin-top:32px; color:var(--muted); font-size:12px; }
@media print { body { background:#fff; } details { display:block; } .card, table { break-inside:avoid; } }
</style>
</head>
<body><main>
<h1>$(ConvertTo-HtmlText (T 'rep.title'))</h1>
<div class="meta">$(ConvertTo-HtmlText $Cycle.Computer) · $(ConvertTo-HtmlText $period) · VDI-ImageMaint $(ConvertTo-HtmlText $script:ToolVersion) · <span class="badge $status">$(ConvertTo-HtmlText $statusText)</span></div>
$pending
<div class="cards">$cards</div>

<h2>$(ConvertTo-HtmlText (T 'rep.sec.problems')) ($($errs.Count + $warns.Count))</h2>
<div class="scroll">$(New-HtmlTable -Rows @($errs + $warns) -Columns $colEv -RowClass $levelCls -Empty (T 'rep.noProblems'))</div>

<h2>$(ConvertTo-HtmlText (T 'rep.sec.apps')) ($($diff.Count))</h2>
<div class="scroll">$(New-HtmlTable -Rows $diffRows -Columns $colDiff -RowClass { param($r) $r.K } -Empty (T 'rep.noChanges'))</div>

<h2>$(ConvertTo-HtmlText (T 'rep.sec.updates')) ($($updates.Count))</h2>
<div class="scroll">$(New-HtmlTable -Rows $updates -Columns $colUpd -RowClass { param($r) if ($r.Result -in 'Succeeded', 'SucceededWithErrors') { '' } else { 'err' } } -Empty (T 'rep.none'))</div>

<h2>$(ConvertTo-HtmlText (T 'rep.sec.packages')) ($($packages.Count))</h2>
<div class="scroll">$(New-HtmlTable -Rows $packages -Columns $colPkg -RowClass { param($r) if ($r.Result -eq 'failed') { 'err' } else { '' } } -Empty (T 'rep.none'))</div>

<h2>$(ConvertTo-HtmlText (T 'rep.sec.infra'))</h2>
<div class="scroll">$(New-HtmlTable -Rows $Facts.Infra -Columns $colInfra -Empty (T 'rep.none'))</div>

<h2>$(ConvertTo-HtmlText (T 'rep.sec.seal'))</h2>
<p>$(ConvertTo-HtmlText (T 'rep.sealLine' $(if ($Facts.Sealed) { T 'rep.sealed' } else { T 'rep.notSealed' }) $Facts.SealCreated $Facts.PoliciesSet $Facts.PoliciesAll $Facts.ActiveTasks))</p>
<div class="scroll">$(New-HtmlTable -Rows $Facts.Services -Columns $colSvc -RowClass { param($r) if ($r.Start -eq 'Disabled') { '' } else { 'warn' } } -Empty (T 'rep.none'))</div>

<h2>$(ConvertTo-HtmlText (T 'rep.sec.runs')) ($($runs.Count))</h2>
<div class="scroll">$(New-HtmlTable -Rows $runRows -Columns $colRun -RowClass { param($r) if ("$($r.Exit)" -notin '0', '-') { 'err' } else { '' } } -Empty (T 'rep.none'))</div>
$runLogs

<footer>$(ConvertTo-HtmlText (T 'rep.footer' (Get-Date -Format 'yyyy-MM-dd HH:mm') $LogDir $script:CycleFile))</footer>
</main></body></html>
"@
    $null = New-Item -ItemType Directory -Path $OutDir -Force
    $path = Join-Path $OutDir ('VDI-ImageMaint_{0}_{1}.html' -f $Cycle.Computer, $Cycle.Id)
    [IO.File]::WriteAllText($path, $html, [Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-Report {
    # -Mode Report: the open cycle, otherwise the last closed one
    $c = Read-Cycle
    if (-not $c) {
        $last = @(Get-ChildItem -Path $script:ReportDir -Filter 'cycle_*.json' -ErrorAction SilentlyContinue | Sort-Object Name) | Select-Object -Last 1
        if ($last) { $c = Read-Cycle -Path $last.FullName }
    }
    if (-not $c) { Write-Log (T 'rep.noCycle') WARN; return }
    $path = New-CycleReport -Cycle $c
    Write-Log (T 'rep.written' $path) OK
}
