# winget: discovery, upgrade table parsing, per-app updates, installs from the manifest, export.
# winget never runs as SYSTEM (it would update apps for the SYSTEM account only).

function Find-WingetExe {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object { try { [version](($_.Directory.Name -split '_')[1]) } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1
    if ($p) { return $p.FullName }
    return $null
}

function Initialize-Winget {
    if ($script:WingetExe) { return $true }
    $exe = Find-WingetExe
    if (-not $exe) {
        # App Installer is often present but not registered for the current account on VDI images
        Write-Log (T 'winget.register') WARN
        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
            Start-Sleep -Seconds 3
            $exe = Find-WingetExe
        } catch { Write-Log (T 'winget.registerFailed' $_.Exception.Message) WARN }
    }
    if (-not $exe) {
        Write-Log (T 'winget.missing') ERR
        return $false
    }
    $script:WingetExe = $exe
    $ver = (Invoke-Winget -Arguments @('--version') | Select-Object -Last 1)
    Write-Log "winget $ver ($exe)" OK
    [void](Invoke-Winget -Arguments @('source', 'update', '--disable-interactivity'))
    if ($script:WingetExit -ne 0) { Write-Log (T 'winget.sourceUpdate' $script:WingetExit) WARN }
    return $true
}

function Invoke-Winget {
    param([string[]]$Arguments)
    # PS 5.1: native stderr with 2>&1 and EAP=Stop becomes a terminating error - Continue locally
    $ErrorActionPreference = 'Continue'
    $prevEnc = $null
    try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    try {
        $out = @(& $script:WingetExe @Arguments 2>&1 | ForEach-Object {
            # drop the progress animation (\r, backspace) - keep the last state of the line
            (("$_" -split "`r")[-1]) -replace "[\x08]", ''
        })
        $script:WingetExit = $LASTEXITCODE
    } finally {
        if ($prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } }
    }
    return $out
}

function Get-WingetColumn {
    param([string]$Line, [int[]]$Cols, [int]$Index)
    $start = $Cols[$Index]
    if ($start -ge $Line.Length) { return '' }
    $end = if ($Index + 1 -lt $Cols.Count) { [Math]::Min($Cols[$Index + 1], $Line.Length) } else { $Line.Length }
    return $Line.Substring($start, $end - $start).Trim()
}

function ConvertFrom-WingetTable {
    # Pure parser of 'winget upgrade' output by column positions (independent of the header language).
    # Returns objects Name, Id, Version, Available, Source; no table = no upgrades.
    param([string[]]$Lines)
    $Lines = @($Lines)
    $sep = -1
    for ($i = 1; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^\s*-{10,}\s*$') { $sep = $i; break } }
    if ($sep -lt 1) { return @() }
    $header = $Lines[$sep - 1]
    $cols = @([regex]::Matches($header, '\S+') | ForEach-Object { $_.Index })
    if ($cols.Count -lt 4) { Write-Log (T 'winget.header' $header) WARN; return @() }
    $rows = @()
    for ($i = $sep + 1; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if ([string]::IsNullOrWhiteSpace($l) -or $l.Length -le $cols[3]) { break }   # end of table / footer
        $id = Get-WingetColumn $l $cols 1
        if (-not $id) { continue }
        $rows += [pscustomobject]@{
            Name      = Get-WingetColumn $l $cols 0
            Id        = $id
            Version   = Get-WingetColumn $l $cols 2
            Available = Get-WingetColumn $l $cols 3
            Source    = $(if ($cols.Count -ge 5) { Get-WingetColumn $l $cols 4 } else { '' })
        }
    }
    return $rows
}

function Get-WingetUpgrades {
    # Action: update | skip (with a localized Reason)
    $a = @('upgrade', '--accept-source-agreements', '--disable-interactivity')
    if ($WingetIncludeUnknown) { $a += '--include-unknown' }
    $pkgs = @()
    foreach ($r in @(ConvertFrom-WingetTable -Lines (Invoke-Winget -Arguments $a))) {
        $action = 'update'; $reason = ''
        if ($r.Id -match '…|\.\.\.$') {
            $action = 'skip'; $reason = T 'winget.skip.truncated'
        } elseif ($WingetStoreIds -contains $r.Id) {
            $action = 'skip'; $reason = $(if ($r.Id -eq 'Microsoft.Teams') { T 'winget.skip.teams' } else { T 'winget.skip.store' })
        } elseif ($WingetExcludeIds -contains $r.Id) {
            $action = 'skip'; $reason = 'WingetExcludeIds'
        } elseif ($r.Name -match $WingetExcludePattern -or $r.Id -match $WingetExcludePattern) {
            $action = 'skip'; $reason = T 'winget.skip.excluded'
        }
        $pkgs += [pscustomobject]@{
            Name = $r.Name; Id = $r.Id; Version = $r.Version; Available = $r.Available; Source = $r.Source
            Action = $action; Reason = $reason
        }
    }
    return $pkgs
}

function Show-WingetList {
    Write-Log (T 'winget.list.step') STEP
    if (-not (Initialize-Winget)) { return }
    $pkgs = @(Get-WingetUpgrades)
    if ($WingetAll) {
        if ($pkgs.Count -eq 0) { Write-Log (T 'winget.none') OK; return }
        $pkgs | Select-Object Name, Id, Version, Available, @{ n = 'Action'; e = { T "winget.action.$($_.Action)" } }, Reason |
            Format-Table -AutoSize | Out-String -Width 250 | Write-Host
        $n = @($pkgs | Where-Object { $_.Action -eq 'update' }).Count
        Write-Log (T 'winget.list.summary' $n ($pkgs.Count - $n))
    } else {
        $rows = foreach ($id in @(Get-WingetIdList)) {
            $hit = $pkgs | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            [pscustomobject]@{
                Id        = $id
                Version   = $(if ($hit) { $hit.Version } else { '' })
                Available = $(if ($hit) { $hit.Available } else { T 'winget.list.current' })
            }
        }
        $rows | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
        Write-Log (T 'winget.list.hint')
    }
}

function Get-ManifestWingetIds {
    # "Winget": { "Install": [ ... ] } - apps chosen in -Mode Configure
    $mp = Get-ManifestPath
    if (-not (Test-Path $mp)) { return @() }
    try { $m = Get-Content -Path $mp -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @() }
    return @(@(Get-PV (Get-PV $m 'Winget') 'Install' @()) | ForEach-Object { [string]$_ } | Where-Object { $_ })
}

function Get-WingetIdList {
    # Without an explicit -WingetIds: the default list plus the apps chosen in -Mode Configure
    $list = @($WingetIds)
    if (-not $script:BoundParams.ContainsKey('WingetIds')) { $list = @($list + @(Get-ManifestWingetIds) | Select-Object -Unique) }
    return $list
}

function Install-WingetApps {
    # Machine-wide install of Winget.Install apps that are not in the image yet
    param([switch]$DryRun)
    $ids = @(Get-ManifestWingetIds)
    if ($ids.Count -eq 0) { return }
    Write-Log $(if ($DryRun) { T 'winget.install.plan' } else { T 'winget.install.step' }) STEP
    if ($isSystem) { Write-Log (T 'winget.system') WARN; return }
    if (-not (Initialize-Winget)) { return }
    foreach ($id in $ids) {
        [void](Invoke-Winget -Arguments @('list', '--id', $id, '--exact', '--accept-source-agreements', '--disable-interactivity'))
        if ($script:WingetExit -eq 0) { Write-Log (T 'winget.installed' $id); continue }
        if ($DryRun) { Write-Log (T 'winget.toInstall' $id) WARN; continue }
        $out = Invoke-Winget -Arguments @('install', '--id', $id, '--exact', '--silent', '--scope', 'machine',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        switch ($script:WingetExit) {
            0          { Write-Log (T 'winget.install.ok' $id) OK }
            0x8A150061 { Write-Log (T 'winget.install.already' $id) }
            0x8A150010 { Write-Log (T 'winget.install.noMachine' $id) WARN }
            default {
                Write-Log (T 'winget.install.failed' $id $script:WingetExit) WARN
                $out | Where-Object { "$_".Trim() } | Select-Object -Last 4 | ForEach-Object { Write-Log "    $_" }
            }
        }
    }
}

function Update-WingetPackage {
    param([string]$Id, [string]$Label)
    $a = @('upgrade', '--id', $Id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($WingetIncludeUnknown) { $a += '--include-unknown' }
    $out = Invoke-Winget -Arguments $a
    $rc = $script:WingetExit
    switch ($rc) {
        0           { Write-Log (T 'winget.upd.ok' $Label) OK }
        -1978335189 { Write-Log (T 'winget.upd.current' $Label) }
        -1978335212 { Write-Log (T 'winget.upd.notInstalled' $Label) }
        default {
            Write-Log (T 'winget.upd.code' $Label $rc) WARN
            $out | Where-Object { "$_".Trim() } | Select-Object -Last 4 | ForEach-Object { Write-Log "    $_" }
        }
    }
    return $rc
}

function Update-WingetApps {
    Write-Log $(if ($WingetAll) { T 'winget.upd.stepAll' } else { T 'winget.upd.stepList' }) STEP
    if (-not (Initialize-Winget)) { return }

    if (-not $WingetAll) {
        foreach ($id in @(Get-WingetIdList)) {
            if ($WingetExcludeIds -contains $id -or $WingetStoreIds -contains $id) { Write-Log (T 'winget.upd.skipped' $id); continue }
            [void](Update-WingetPackage -Id $id -Label $id)
        }
        return
    }

    $pkgs = @(Get-WingetUpgrades)
    if ($pkgs.Count -eq 0) { Write-Log (T 'winget.none') OK; return }
    foreach ($p in @($pkgs | Where-Object { $_.Action -ne 'update' })) {
        Write-Log (T 'winget.upd.skip' $p.Name $p.Id $p.Reason) WARN
    }
    $todo = @($pkgs | Where-Object { $_.Action -eq 'update' })
    $ok = 0; $fail = 0
    foreach ($p in $todo) {
        Write-Log ("{0} [{1}] {2} -> {3}" -f $p.Name, $p.Id, $p.Version, $p.Available)
        $rc = Update-WingetPackage -Id $p.Id -Label $p.Id
        if ($rc -eq 0) { $ok++ } elseif ($rc -ne -1978335189) { $fail++ }
    }
    Write-Log (T 'winget.upd.summary' $ok $fail ($pkgs.Count - $todo.Count)) $(if ($fail) { 'WARN' } else { 'OK' })

    # Check: anything left (e.g. a package that needed the app to be closed)
    $left = @(Get-WingetUpgrades | Where-Object { $_.Action -eq 'update' })
    if ($left.Count) { Write-Log (T 'winget.upd.left' (($left | ForEach-Object { $_.Id }) -join ', ')) WARN }
}

function Export-WingetPackages {
    param([string]$Dir)
    if (-not (Initialize-Winget)) { return }
    $f = Join-Path $Dir 'winget-export.json'
    [void](Invoke-Winget -Arguments @('export', '-o', $f, '--include-versions', '--accept-source-agreements', '--disable-interactivity'))
    if (Test-Path $f) { Write-Log (T 'winget.export.ok' $f) OK } else { Write-Log (T 'winget.export.failed' $script:WingetExit) WARN }
}
