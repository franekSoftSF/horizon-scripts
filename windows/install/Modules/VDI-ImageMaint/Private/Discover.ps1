# Discover: builds manifest entries for files in C:\install that have none; Init: folder structure.

function Get-NormalizedName {
    param([string]$Name)
    $n = $Name.ToLower()
    $n = $n -replace '\((x64|x86|64-bit|32-bit)[^)]*\)', ' '
    $n = $n -replace '\b(x64|x86|x86_64|amd64|win32|64-bit|32-bit)\b', ' '
    $n = $n -replace '\d+([._-]\d+)+', ' ' -replace '\b\d{4}\b', ' '
    $n = $n -replace '[^a-z0-9+ ]', ' ' -replace '\s+', ' '
    return $n.Trim()
}

function Get-PackageFileInfo {
    param($File)
    $ext = $File.Extension.ToLower()
    $type = switch -Regex ($ext) {
        '^\.(msix|msixbundle|appx|appxbundle)$' { 'appx' }
        '^\.(msi|msp|msu|cab|exe|ps1|zip)$'     { $ext.TrimStart('.') }
        default                                 { '' }
    }
    $name = ''
    if ($ext -eq '.msi') { $name = [string](Get-MsiProperty $File.FullName 'ProductName') }
    elseif ($ext -eq '.exe') { $name = [string]$File.VersionInfo.ProductName }
    if (-not $name) { $name = $File.BaseName }
    $arch = if ($File.Name -match '(?i)x86_64|x64|amd64|64-bit') { 'x64' } elseif ($File.Name -match '(?i)x86|win32|32-bit') { 'x86' } else { '' }
    [pscustomobject]@{ File = $File; Type = $type; Product = $name.Trim(); Norm = (Get-NormalizedName $name); Arch = $arch; Version = (Get-FileVersionText $File) }
}

function New-PackageId {
    param([string]$Name, [hashtable]$Used)
    $base = (Get-Culture).TextInfo.ToTitleCase((Get-NormalizedName $Name)) -replace '[^A-Za-z0-9]', ''
    if (-not $base) { $base = 'Package' }
    if ($base.Length -gt 40) { $base = $base.Substring(0, 40) }
    $id = $base; $i = 2
    while ($Used.ContainsKey($id)) { $id = "$base$i"; $i++ }
    $Used[$id] = $true
    return $id
}

function Invoke-Discover {
    Write-Log (T 'disc.step') STEP
    $m = Get-PackageManifest
    if (-not $m) { return }
    $packages = New-Object System.Collections.ArrayList
    foreach ($x in @(Get-PV $m 'Packages' @())) { [void]$packages.Add($x) }
    $ignore = New-Object System.Collections.ArrayList
    foreach ($x in @(Get-PV $m 'Ignore' @())) { [void]$ignore.Add($x) }
    $used = @{}; foreach ($x in $packages) { $used[[string](Get-PV $x 'Id' '')] = $true }
    $order = 60
    foreach ($x in $packages) { $o = [int](Get-PV $x 'Order' 0); if ($o -ge $order -and $o -lt 90) { $order = $o + 1 } }

    $installed = @(Get-InstalledApps)
    $infos = @(Get-UnassignedFiles -ManifestObj $m | ForEach-Object { Get-PackageFileInfo $_ })
    if ($infos.Count -eq 0) { Write-Log (T 'disc.complete') OK; return }

    $report = @()
    $patchDirs = @{}
    foreach ($i in $infos) {
        $rel = Get-RelativePath $i.File.FullName
        # 1) x86 variant when an x64 of the same product exists -> Ignore
        if ($i.Arch -eq 'x86') {
            $twin = @($infos + @() | Where-Object { $_.Arch -eq 'x64' -and $_.Norm -eq $i.Norm -and $_.File.DirectoryName -eq $i.File.DirectoryName })
            $twinAssigned = @(Get-ChildItem -Path $i.File.DirectoryName -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $i.File.Name -and $_.Extension -eq $i.File.Extension -and $_.Name -match '(?i)x64|x86_64|amd64' -and (Get-NormalizedName ([string](Get-MsiProperty $_.FullName 'ProductName'))) -eq $i.Norm })
            if ($twin.Count -or $twinAssigned.Count -or ($installed | Where-Object { (Get-NormalizedName $_.Name) -eq $i.Norm -and $_.Arch -eq 'x64' })) {
                [void]$ignore.Add('^' + [regex]::Escape($rel) + '$')
                $report += [pscustomobject]@{ File = $rel; Decision = 'Ignore'; Id = ''; Reason = (T 'disc.x86') }
                continue
            }
        }
        # 2) MSU/CAB/MSP patches outside Patches -> one entry for the whole folder
        if ($i.Type -in 'msu', 'cab', 'msp') {
            $dir = Split-Path $rel -Parent
            $key = "$dir|$($i.Type)"
            if ($patchDirs.ContainsKey($key)) { continue }
            $patchDirs[$key] = $true
            $id = New-PackageId ("Patches $dir $($i.Type)") $used
            $pat = $(if ($dir) { "$dir\*.$($i.Type)" } else { "*.$($i.Type)" })
            [void]$packages.Add([pscustomobject]([ordered]@{
                Id = $id; Name = (T 'disc.patchName' $i.Type.ToUpper() $(if ($dir) { $dir } else { T 'disc.rootDir' })); Enabled = $true; Order = 7
                Type = $i.Type; File = $pat; Recurse = $false; Multiple = $true
                Detect = [pscustomobject]@{ Type = $(if ($i.Type -eq 'msp') { 'Always' } else { 'Hotfix' }) }
                RebootAfter = ($i.Type -ne 'msp')
            }))
            $report += [pscustomobject]@{ File = $pat; Decision = (T 'disc.newOn'); Id = $id; Reason = (T 'disc.byKb') }
            continue
        }
        if (-not $i.Type -or $i.Type -eq 'zip') {
            $report += [pscustomobject]@{ File = $rel; Decision = (T 'disc.skipped'); Id = ''; Reason = (T 'disc.archive') }
            continue
        }
        # 3) match with an installed application
        $app = $installed | Where-Object {
            $n = Get-NormalizedName $_.Name
            $n -and ($n -eq $i.Norm -or ($n.Length -ge 8 -and $i.Norm.Length -ge 8 -and ($n.Contains($i.Norm) -or $i.Norm.Contains($n))))
        } | Select-Object -First 1
        $id = New-PackageId $i.Product $used
        $leaf = ($i.File.Name -replace '\d+([._-]\d+)+', '*' -replace '\b\d{4}\b', '*') -replace '\*(\s*\*)+', '*'
        $isInfra = $i.Product -match $InfraPattern
        $entry = [ordered]@{ Id = $id; Name = $i.Product; Enabled = $false; Order = $order; Type = $i.Type; File = $leaf }
        if ($i.Arch -eq 'x64') { $entry['PreferPath'] = '(?i)x64|x86_64|amd64' }
        if ($i.Type -eq 'exe') { $entry['Arguments'] = ''; $entry['_note'] = (T 'disc.exeNote') }
        if ($i.Type -eq 'ps1') { $entry['Detect'] = [pscustomobject]@{ Type = 'Always' } }
        elseif ($i.Type -eq 'appx') { $entry['Detect'] = [pscustomobject]@{ Type = 'Appx'; Name = ($i.File.BaseName -split '_')[0] } }
        elseif ($app) {
            $rx = '^' + ([regex]::Escape($app.Name) -replace '\d+(\\\.\d+)+', '[\d.]+') + '$'
            $entry['Detect'] = [pscustomobject]@{ Type = 'Uninstall'; Name = $rx }
            $entry['RequireInstalled'] = $true
        } else {
            $entry['Detect'] = [pscustomobject]@{ Type = 'Uninstall'; Name = '^' + [regex]::Escape($i.Product) }
            $entry['RequireInstalled'] = $true
        }
        if ($app -and $i.Type -in 'msi', 'appx' -and -not $isInfra) { $entry['Enabled'] = $true }
        if ($isInfra) { $entry['RebootAfter'] = $true }
        $order++
        [void]$packages.Add([pscustomobject]$entry)
        $why = if ($app) { T 'disc.installed' $app.Name $app.Version } else { T 'disc.notInstalled' }
        if ($isInfra) { $why += ' | ' + (T 'disc.infra') }
        $report += [pscustomobject]@{ File = $rel; Decision = $(if ($entry['Enabled']) { T 'disc.newOn' } else { T 'disc.newOff' }); Id = $id; Reason = $why }
    }

    Write-Log (T 'disc.proposals') STEP
    $report | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host

    $out = [ordered]@{}
    foreach ($pp in $m.PSObject.Properties) { if ($pp.Name -notin 'Packages', 'Ignore') { $out[$pp.Name] = $pp.Value } }
    $out['Ignore']   = @($ignore)
    $out['Packages'] = @($packages | Sort-Object { [int](Get-PV $_ 'Order' 100) })
    $json = Format-Json ([pscustomobject]$out | ConvertTo-Json -Depth 10)
    $target = Get-ManifestPath
    if ($Apply) {
        Save-TextWithBackup -Path $target -Text $json
        Write-Log (T 'disc.applied' $target) OK
    } else {
        $prop = [IO.Path]::ChangeExtension($target, '.discovered.json')
        [IO.File]::WriteAllText($prop, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Log (T 'disc.saved' $prop) OK
        Write-Log (T 'disc.applyHint')
    }
}

function Invoke-Init {
    Write-Log (T 'init.step' $InstallDir) STEP
    $dirs = [ordered]@{
        'Patches' = T 'init.patches'
        'Office'  = T 'init.office'
        'FSLogix' = T 'init.fslogix'
        'Horizon' = T 'init.horizon'
        'OSOT'    = T 'init.osot'
        'Teams'   = T 'init.teams'
        'Apps'    = T 'init.apps'
        'Scripts' = T 'init.scripts'
    }
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    foreach ($d in $dirs.Keys) {
        $p = Join-Path $InstallDir $d
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null; Write-Log (T 'init.created' $p) OK }
        else { Write-Log (T 'init.exists' $p) }
    }
    [void](Get-PackageManifest)
    $lines = @((T 'init.readmeTitle' $InstallDir), '', ('START.cmd            ' + (T 'init.readmeStart')), ('VDI-ImageMaint.ps1   ' + (T 'init.readmeScript')), ('packages.json        ' + (T 'init.readmeManifest')), '')
    foreach ($d in $dirs.Keys) { $lines += ('{0,-20} {1}' -f ($d + '\'), $dirs[$d]) }
    $lines += @('', (T 'init.readmeRecursive'), (T 'init.readmeList'))
    $readme = Join-Path $InstallDir 'README-structure.txt'
    Set-Content -Path $readme -Value $lines -Encoding UTF8
    Write-Log (T 'init.readme' $readme) OK
    Write-Log (T 'init.noMove')
}
