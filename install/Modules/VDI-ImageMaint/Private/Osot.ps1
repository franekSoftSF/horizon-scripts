# Omnissa OS Optimization Tool (OSOT). Never run as SYSTEM: OSOT syncs HKCU to the Default User hive.

function Find-Osot {
    if ($OsotPath) {
        if (Test-Path $OsotPath) { return (Get-Item $OsotPath) }
        Write-Log (T 'osot.pathMissing' $OsotPath) WARN; return $null
    }
    if (-not (Test-Path $InstallDir)) { return $null }
    Get-ChildItem -Path $InstallDir -Recurse -File -Include '*OS*Optimization*Tool*.exe', '*OSOT*.exe' -ErrorAction SilentlyContinue |
        Sort-Object @{ Expression = { ConvertTo-Version $_.VersionInfo.FileVersion }; Descending = $true },
                    @{ Expression = { $_.LastWriteTime }; Descending = $true } |
        Select-Object -First 1
}

function Invoke-Osot {
    param([string[]]$Arguments, [string]$Label)
    $script:OsotExit = $null   # exit code of the last run ($null = not run)
    if ($SkipOsot) { return }
    if ($isSystem) { Write-Log (T 'osot.notSystem' $Label); return }
    $exe = Find-Osot
    if (-not $exe) { Write-Log (T 'osot.notFound' $InstallDir $Label) WARN; return }
    $argLine = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' '
    $log = Join-Path $LogDir ('OSOT_{0}_{1}.log' -f $Label, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Write-Log ("OSOT {0} [{1}]: {2}" -f $exe.VersionInfo.FileVersion, $Label, $argLine) STEP
    Write-Log (T 'osot.file' $exe.FullName)
    $p = Start-Process -FilePath $exe.FullName -ArgumentList $argLine -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $script:OsotExit = $p.ExitCode
    Write-Log (T 'osot.exit' $Label $p.ExitCode $log) $(if ($p.ExitCode -eq 0) { 'OK' } else { 'WARN' })
}

function Invoke-OsotEnableUpdates {
    # -o no-item = no template items, common options only
    Invoke-Osot -Label 'EnableUpdates' -Arguments @('-o', 'no-item', '-SyncHkcuToHku', 'disable',
        '-windowsupdate', 'enable', '-officeupdate', 'enable', '-v')
}

function Get-OsotConfig {
    # OSOT configuration: "Osot" section of the manifest + parameter overrides
    $m = $null
    $mp = Get-ManifestPath
    if (Test-Path $mp) { try { $m = Get-Content -Path $mp -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $o = Get-PV $m 'Osot'
    $cfg = [ordered]@{
        Optimize      = [bool](Get-PV $o 'Optimize' $true)
        Template      = [string](Get-PV $o 'Template' '')
        Level         = [string](Get-PV $o 'Level' '')
        SettingsFile  = [string](Get-PV $o 'SettingsFile' '')
        CommonOptions = @(Get-PV $o 'CommonOptions' @('-visualeffect', 'balanced'))
        Finalize      = [string](Get-PV $o 'Finalize' '0 1 3 4 5 8 10 11')
        Report        = [bool](Get-PV $o 'Report' $true)
    }
    # The image build (PostGeneralize) may use a fuller Finalize set than the Day-2 cycle
    if ($script:BuildFinalize) { $cfg.Finalize = [string](Get-PV $o 'FinalizeBuild' $cfg.Finalize) }
    if ($OsotOptimize)     { $cfg.Optimize = $true }
    if ($OsotSkipOptimize) { $cfg.Optimize = $false }
    if ($OsotTemplate)     { $cfg.Template = $OsotTemplate }
    if ($OsotLevel)        { $cfg.Level = $OsotLevel }
    if ($OsotExtraArgs)    { $cfg.CommonOptions = @($cfg.CommonOptions) + @($OsotExtraArgs) }
    if ($OsotFinalize)     { $cfg.Finalize = $(if ($OsotFinalize -eq 'none') { '' } else { $OsotFinalize }) }
    return $cfg
}

function Get-OsotOptimizeArgs {
    param($Cfg)
    $a = @('-o')
    if ($Cfg.Level)    { $a += $Cfg.Level }
    if ($Cfg.Template) { $a += @('-t', $Cfg.Template) }
    if ($Cfg.SettingsFile) {
        $sf = if ([IO.Path]::IsPathRooted($Cfg.SettingsFile)) { $Cfg.SettingsFile } else { Join-Path $InstallDir $Cfg.SettingsFile }
        if (Test-Path $sf) { $a += @('-applyoptimization', $sf) }
        else { Write-Log (T 'osot.noSettings' $sf) }
    }
    $a += @($Cfg.CommonOptions)
    if ($Cfg.Report) {
        $a += @('-r', (Join-Path $LogDir ('OSOT_Report_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))))
    }
    return $a
}

function Show-OsotConfig {
    $o = Find-Osot
    if ($o) { Write-Log (T 'osot.found' $o.FullName $o.VersionInfo.FileVersion) OK } else { Write-Log (T 'osot.absent' $InstallDir) WARN }
    $c = Get-OsotConfig
    $def = T 'osot.default'
    Write-Log (T 'osot.cfg' $c.Optimize $(if ($c.Template) { $c.Template } else { $def }) $(if ($c.Level) { $c.Level } else { $def }) $(if ($c.SettingsFile) { $c.SettingsFile } else { '-' }))
    Write-Log (T 'osot.common' (@($c.CommonOptions) -join ' '))
    Write-Log (T 'osot.finalize' $(if ($c.Finalize) { "-f $($c.Finalize)" } else { T 'osot.off' }))
}

function Invoke-OsotSealPre {
    # Image optimization (or only turning updates off when Optimize=false)
    $cfg = Get-OsotConfig
    if ($cfg.Optimize) { $a = @(Get-OsotOptimizeArgs $cfg) }
    else { $a = @('-o', 'no-item', '-SyncHkcuToHku', 'disable') }
    $a += @('-windowsupdate', 'disable', '-officeupdate', 'disable', '-v')
    Invoke-Osot -Label $(if ($cfg.Optimize) { 'Optimize' } else { 'DisableUpdates' }) -Arguments $a
}

function Copy-FinalizeTool {
    # OSOT Finalize looks for LGPO.exe (step 8) / sdelete64.exe (step 7) in System32 - copy them there from C:\install
    param([string[]]$Steps)
    $sys32 = Join-Path $env:SystemRoot 'System32'
    foreach ($t in @(@('8', 'LGPO.exe'), @('7', 'sdelete64.exe'))) {
        if ($Steps -notcontains $t[0] -and $Steps -notcontains 'all') { continue }
        if (Test-Path (Join-Path $sys32 $t[1])) { continue }
        $src = $null
        if (Test-Path $InstallDir) { $src = Get-ChildItem -Path $InstallDir -Recurse -File -Filter $t[1] -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if (-not $src) { Write-Log (T 'osot.toolMissing' $t[0] $t[1]) WARN; continue }
        if (-not (Test-TrustedFile -Path $src.FullName -SignerPattern 'O=Microsoft Corporation')) { Write-Log (T 'dl.badSig' $src.Name '-' '-') WARN; continue }
        Copy-Item -Path $src.FullName -Destination $sys32 -Force
        Write-Log (T 'osot.toolCopied' $t[1] $sys32 $t[0]) OK
    }
}

function Invoke-OsotFinalize {
    $cfg = Get-OsotConfig
    if (-not $cfg.Finalize) { Write-Log (T 'osot.finalizeOff'); return }
    $steps = @($cfg.Finalize -split '\s+' | Where-Object { $_ })
    if (-not $SkipOsot -and -not $isSystem) { Copy-FinalizeTool -Steps $steps }
    Invoke-Osot -Label 'Finalize' -Arguments (@('-f') + $steps + @('-v'))
}
